import Darwin
import Foundation

public enum Framing {
  public static let maximum = 65536
  public static func encode(_ data: Data) throws -> Data {
    guard !data.isEmpty, data.count <= maximum else {
      throw FocusFailure.invalid("Native message exceeds the 64 KiB limit.")
    }
    var n = UInt32(data.count)
    var result = withUnsafeBytes(of: &n) { Data($0) }
    result.append(data)
    return result
  }
  public static func read(fd: Int32) throws -> Data? {
    guard let prefix = try exact(fd: fd, count: 4, allowEOF: true) else { return nil }
    let length = prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    guard length > 0, length <= maximum else {
      throw FocusFailure.invalid("Invalid native message length.")
    }
    return try exact(fd: fd, count: Int(length), allowEOF: false)
  }
  public static func write(_ data: Data, fd: Int32) throws {
    let frame = try encode(data)
    try frame.withUnsafeBytes { buffer in
      var sent = 0
      while sent < frame.count {
        let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: sent), frame.count - sent)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { throw FocusFailure.unavailable("Native channel closed while writing.") }
        sent += n
      }
    }
  }
  private static func exact(fd: Int32, count: Int, allowEOF: Bool) throws -> Data? {
    var data = Data(count: count)
    var readCount = 0
    try data.withUnsafeMutableBytes { buffer in
      while readCount < count {
        let n = Darwin.read(fd, buffer.baseAddress!.advanced(by: readCount), count - readCount)
        if n < 0 && errno == EINTR { continue }
        if n == 0 && readCount == 0 && allowEOF { return }
        guard n > 0 else {
          throw FocusFailure.unavailable("Native channel ended with an incomplete frame.")
        }
        readCount += n
      }
    }
    return readCount == 0 ? nil : data
  }
}
public enum LocalSocket {
  public static func address(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      throw FocusFailure.invalid("The local bridge path is too long.")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.initializeMemory(as: UInt8.self, repeating: 0)
      buffer.copyBytes(from: bytes)
    }
    return address
  }
  public static func connect(path: String) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw FocusFailure.unavailable("Could not create local bridge socket.") }
    var address = try address(path)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if result != 0 {
      Darwin.close(fd)
      throw FocusFailure.unavailable(
        "OutlookFocus is not running. Open the macOS app, then retry connection.")
    }
    var peer: uid_t = 0
    var group: gid_t = 0
    guard getpeereid(fd, &peer, &group) == 0, peer == getuid() else {
      Darwin.close(fd)
      throw FocusFailure.invalid("Local bridge belongs to a different user.")
    }
    return fd
  }
}
public final class BridgeServer: @unchecked Sendable {
  private final class Client {
    let fd: Int32
    let lock = NSLock()
    var ready = false
    private var closed = false
    init(_ fd: Int32) { self.fd = fd }
    func send(_ envelope: Envelope) throws {
      let data = try envelope.encoded()
      lock.lock()
      defer { lock.unlock() }
      guard !closed else { throw FocusFailure.unavailable("Native connection is closed.") }
      try Framing.write(data, fd: fd)
    }
    func close() {
      lock.lock()
      defer { lock.unlock() }
      if !closed {
        closed = true
        Darwin.close(fd)
      }
    }
    func shutdown() {
      lock.lock()
      defer { lock.unlock() }
      if !closed { Darwin.shutdown(fd, SHUT_RDWR) }
    }
  }
  private func listening(_ fd: Int32) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return listener == fd
  }
  private let paths: AppPaths
  private let queue = DispatchQueue(label: "OutlookFocus.bridge", attributes: .concurrent)
  private let lock = NSLock()
  private var listener: Int32 = -1
  private var ownsSocket = false
  private var clients: [UUID: Client] = [:]
  public var onMessage: (@Sendable (UUID, Envelope) -> Void)?
  public var onDisconnect: (@Sendable (UUID) -> Void)?
  public init(paths: AppPaths = AppPaths()) { self.paths = paths }
  public func start() throws {
    signal(SIGPIPE, SIG_IGN)
    try paths.prepare()
    if FileManager.default.fileExists(atPath: paths.socket.path) {
      if let old = try? LocalSocket.connect(path: paths.socket.path) {
        Darwin.close(old)
        throw FocusFailure.unavailable("Another OutlookFocus instance is already running.")
      }
      let a = try FileManager.default.attributesOfItem(atPath: paths.socket.path)
      guard a[.type] as? FileAttributeType == .typeSocket,
        (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
      else { throw FocusFailure.invalid("The bridge path is not a user-owned socket.") }
      try FileManager.default.removeItem(at: paths.socket)
    }
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw FocusFailure.unavailable("Could not create bridge listener.") }
    var address = try LocalSocket.address(paths.socket.path)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, chmod(paths.socket.path, 0o600) == 0, Darwin.listen(fd, 4) == 0 else {
      Darwin.close(fd)
      throw FocusFailure.unavailable("Could not secure the local bridge listener.")
    }
    lock.lock()
    listener = fd
    ownsSocket = true
    lock.unlock()
    queue.async { [weak self] in
      while let self, self.listening(fd) {
        let client = Darwin.accept(fd, nil, nil)
        if client < 0 {
          if errno == EINTR { continue }
          break
        }
        self.handle(client)
      }
    }
  }
  private func handle(_ fd: Int32) {
    var peer: uid_t = 0
    var group: gid_t = 0
    guard getpeereid(fd, &peer, &group) == 0, peer == getuid() else {
      Darwin.close(fd)
      return
    }
    let id = UUID()
    let client = Client(fd)
    lock.lock()
    if clients.count >= 8 {
      lock.unlock()
      Darwin.close(fd)
      return
    }
    clients[id] = client
    lock.unlock()
    queue.async { [weak self] in
      guard let self else {
        Darwin.close(fd)
        return
      }
      defer {
        self.lock.lock()
        self.clients.removeValue(forKey: id)
        self.lock.unlock()
        client.close()
        self.onDisconnect?(id)
      }
      do {
        var count = 0
        while let data = try Framing.read(fd: fd) {
          let message = try Envelope.decoded(data)
          if count == 0 {
            guard message.type == .hello, let origin = message.payload.origin,
              try self.allowedOrigins().contains(origin)
            else { throw FocusFailure.invalid("Unregistered native origin.") }
            self.lock.lock()
            client.ready = true
            self.lock.unlock()
          }
          count += 1
          self.onMessage?(id, message)
        }
      } catch {
        // Invalid or closed channels are disconnected without logging payloads.
      }
    }
  }
  private func allowedOrigins() throws -> Set<String> {
    let a = try FileManager.default.attributesOfItem(atPath: paths.origins.path)
    guard (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
      ((a[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0
    else { throw FocusFailure.invalid("Native origin configuration must be private to this user.") }
    return Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: paths.origins)))
  }
  public func send(_ envelope: Envelope, to id: UUID) throws {
    lock.lock()
    let client = clients[id]
    let ready = client?.ready ?? false
    lock.unlock()
    guard let client, ready else {
      throw FocusFailure.unavailable("Chrome extension is disconnected.")
    }
    try client.send(envelope)
  }
  public func stop() {
    lock.lock()
    let fd = listener
    listener = -1
    let owned = ownsSocket
    ownsSocket = false
    let connections = Array(clients.values)
    lock.unlock()
    if owned { try? FileManager.default.removeItem(at: paths.socket) }
    if fd >= 0 {
      Darwin.shutdown(fd, SHUT_RDWR)
      Darwin.close(fd)
    }
    for client in connections { client.shutdown() }
  }
  deinit { stop() }
}
