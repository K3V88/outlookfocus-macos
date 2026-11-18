import Darwin
import Foundation
import OutlookFocusCore

signal(SIGPIPE, SIG_IGN)
let paths = AppPaths(
  directory: ProcessInfo.processInfo.environment["OUTLOOKFOCUS_TEST_SUPPORT_DIR"].map {
    URL(fileURLWithPath: $0)
  })
do {
  guard CommandLine.arguments.count >= 2 else {
    throw FocusFailure.invalid("Chrome must supply an extension origin.")
  }
  let origin = CommandLine.arguments[1]
  guard origin.range(of: "^chrome-extension://[a-p]{32}/$", options: .regularExpression) != nil
  else { throw FocusFailure.invalid("Invalid Chrome origin.") }
  let attributes = try FileManager.default.attributesOfItem(atPath: paths.origins.path)
  guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
    ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0
  else { throw FocusFailure.invalid("Native host origin file is not private.") }
  let origins = try JSONDecoder().decode([String].self, from: Data(contentsOf: paths.origins))
  guard origins.contains(origin) else {
    throw FocusFailure.invalid("This extension has not been registered.")
  }
  let socket = try LocalSocket.connect(path: paths.socket.path)
  var hello = Payload()
  hello.origin = origin
  try Framing.write(Envelope(.hello, payload: hello).encoded(), fd: socket)
  // One writer per direction: no interleaved frames and no stdout diagnostics.
  DispatchQueue.global().async {
    do {
      while let data = try Framing.read(fd: socket) {
        let message = try Envelope.decoded(data)
        try Framing.write(message.encoded(), fd: STDOUT_FILENO)
      }
    } catch {}
    Darwin.shutdown(socket, SHUT_RDWR)
    Darwin.close(socket)
    exit(0)
  }
  while let data = try Framing.read(fd: STDIN_FILENO) {
    let message = try Envelope.decoded(data)
    guard message.type != .hello else {
      throw FocusFailure.invalid("The host controls its own handshake.")
    }
    try Framing.write(message.encoded(), fd: socket)
  }
  Darwin.shutdown(socket, SHUT_RDWR)
  Darwin.close(socket)
} catch {
  var payload = Payload()
  payload.connected = false
  payload.error = "OutlookFocus host unavailable. Open the Mac app and verify host registration."
  if let data = try? Envelope(.connectionStatus, payload: payload).encoded() {
    try? Framing.write(data, fd: STDOUT_FILENO)
  }
  exit(1)
}
