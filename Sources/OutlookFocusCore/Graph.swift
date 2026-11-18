import CryptoKit
import Foundation

public struct MailRecord: Codable, Equatable, Sendable {
  public var id: String
  public var receivedDateTime: String?
  public var importance: String?
  public var isDraft: Bool?
  public var removed: Removal?
  public struct Removal: Codable, Equatable, Sendable { public var reason: String? }
  enum CodingKeys: String, CodingKey {
    case id, receivedDateTime, importance, isDraft
    case removed = "@removed"
  }
  public init(id: String, received: Date?, importance: String = "normal", removed: Bool = false) {
    self.id = id
    receivedDateTime = received.map { InternetDate.string($0) }
    self.importance = importance
    isDraft = false
    self.removed = removed ? Removal(reason: "deleted") : nil
  }
}
public struct DeltaPage: Codable, Sendable {
  public var value: [MailRecord]
  public var nextLink: String?
  public var deltaLink: String?
  enum CodingKeys: String, CodingKey {
    case value
    case nextLink = "@odata.nextLink"
    case deltaLink = "@odata.deltaLink"
  }
  public init(value: [MailRecord], nextLink: String? = nil, deltaLink: String? = nil) {
    self.value = value
    self.nextLink = nextLink
    self.deltaLink = deltaLink
  }
}
public struct SyncState: Codable, Sendable, Equatable {
  public var account: String
  public var cursor: String?
  public var baseline: Bool
  public var lastCheck: Date?
  public var seen: [String: Date]
  public init(
    account: String, cursor: String? = nil, baseline: Bool = false, lastCheck: Date? = nil,
    seen: [String: Date] = [:]
  ) {
    self.account = account
    self.cursor = cursor
    self.baseline = baseline
    self.lastCheck = lastCheck
    self.seen = seen
  }
  public mutating func ingest(_ messages: [MailRecord], cycleStart: Date) -> [MailRecord] {
    var fresh: [MailRecord] = []
    for mail in messages {
      guard !mail.id.isEmpty else { continue }
      let date = mail.receivedDateTime.flatMap { InternetDate.parse($0) }
      let known = seen[mail.id] != nil
      seen[mail.id] = date ?? cycleStart
      if baseline, !known, mail.removed == nil, mail.isDraft != true, let date,
        let cutoff = lastCheck, date > cutoff, date <= cycleStart.addingTimeInterval(300)
      {
        fresh.append(mail)
      }
    }
    return fresh
  }
  public mutating func commit(cursor: String, at date: Date) {
    self.cursor = cursor
    baseline = true
    lastCheck = date
    if seen.count > 20000 {
      seen = Dictionary(
        uniqueKeysWithValues: seen.sorted { $0.value > $1.value }.prefix(20000).map {
          ($0.key, $0.value)
        })
    }
  }
}
public struct SyncOutcome: Sendable {
  public let messages: [MailRecord]
  public let baselineOnly: Bool
  public let checkedAt: Date
}
public protocol DeltaFetching: Sendable { func page(url: URL) async throws -> DeltaPage }
public actor GraphClient: DeltaFetching {
  public static let initialURL = URL(
    string:
      "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta?changeType=created&$select=id,receivedDateTime,importance,isDraft&$top=100"
  )!
  private var notBefore: Date?
  private let transport: any HTTPTransport
  private let token: @Sendable (Bool) async throws -> String
  public init(
    transport: any HTTPTransport = URLSessionTransport(),
    token: @escaping @Sendable (Bool) async throws -> String
  ) {
    self.transport = transport
    self.token = token
  }
  public static func checkedURL(_ value: String) throws -> URL {
    guard let u = URL(string: value), u.scheme == "https", u.host == "graph.microsoft.com",
      u.user == nil, u.password == nil, u.port == nil || u.port == 443,
      u.path.hasPrefix("/v1.0/me/"), u.fragment == nil
    else { throw FocusFailure.invalid("Microsoft Graph returned an invalid synchronization URL.") }
    return u
  }
  public func page(url: URL) async throws -> DeltaPage {
    if let notBefore, notBefore > Date() {
      throw FocusFailure.throttled(notBefore.timeIntervalSinceNow)
    }
    let url = try Self.checkedURL(url.absoluteString)
    for attempt in 0...1 {
      var request = URLRequest(url: url)
      request.setValue(
        "Bearer " + (try await token(attempt == 1)), forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue(
        "IdType=\"ImmutableId\", odata.maxpagesize=100", forHTTPHeaderField: "Prefer")
      let result = try await transport.send(request)
      if result.status == 401 {
        if attempt == 0 { continue }
        throw FocusFailure.authenticationRequired
      }
      if result.status == 410 { throw FocusFailure.cursorExpired }
      if result.status == 429 || result.status == 503 {
        let delay = Self.retryAfter(result.headers["retry-after"]) ?? 30
        notBefore = Date().addingTimeInterval(delay)
        throw FocusFailure.throttled(delay)
      }
      if result.status == 400,
        let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
        let error = json["error"] as? [String: Any], let code = error["code"] as? String,
        ["syncStateNotFound", "InvalidDeltaToken", "SyncStateNotFound"].contains(code)
      {
        throw FocusFailure.cursorExpired
      }
      guard result.status == 200 else { throw FocusFailure.http(result.status) }
      return try JSONDecoder().decode(DeltaPage.self, from: result.data)
    }
    throw FocusFailure.authenticationRequired
  }
  public static func retryAfter(_ value: String?, now: Date = Date()) -> Double? {
    guard let value else { return nil }
    if let seconds = Double(value), seconds.isFinite { return max(1, seconds) }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
    return f.date(from: value).map { max(1, $0.timeIntervalSince(now)) }
  }
}
public struct PendingRound: Codable, Sendable {
  public var account: String
  public var baseCursor: String?
  public var baseLastCheck: Date?
  public var working: SyncState
  public var cycleStart: Date
  public var baselineOnly: Bool
  public var nextURL: String
  public var messages: [MailRecord]
  public var visited: Set<String>
  public var retryAfter: Date?
  public init(state: SyncState, now: Date) {
    account = state.account
    baseCursor = state.cursor
    baseLastCheck = state.lastCheck
    working = state
    cycleStart = now
    baselineOnly = !state.baseline
    nextURL = state.cursor ?? GraphClient.initialURL.absoluteString
    messages = []
    visited = []
  }
}
public actor SyncEngine {
  private let graph: any DeltaFetching
  private let store: SyncStore
  private var busy = false
  private var epoch = 0
  public init(graph: any DeltaFetching, store: SyncStore) {
    self.graph = graph
    self.store = store
  }
  public func synchronize(account: String, now: Date = Date()) async throws -> SyncOutcome? {
    guard !busy else { return nil }
    busy = true
    let version = epoch
    defer { busy = false }
    var state = try await store.load(account: account) ?? SyncState(account: account)
    for recovery in 0...1 {
      let checkpoint = try await store.loadPending(account: account)
      var round: PendingRound
      if let checkpoint, checkpoint.baseCursor == state.cursor,
        checkpoint.baseLastCheck == state.lastCheck
      {
        round = checkpoint
      } else {
        round = PendingRound(state: state, now: now)
      }
      if let after = round.retryAfter, after > Date() {
        throw FocusFailure.throttled(after.timeIntervalSinceNow)
      }
      do {
        // A bounded round makes progress without monopolizing the mailbox request budget.
        for _ in 0..<20 {
          try Task.checkCancellation()
          guard version == epoch else { throw CancellationError() }
          let url = try GraphClient.checkedURL(round.nextURL)
          let fingerprint = PKCE.base64(Data(SHA256.hash(data: Data(url.absoluteString.utf8))))
          guard !round.visited.contains(fingerprint), round.visited.count < 10000 else {
            throw FocusFailure.invalid(
              "Graph repeated a pagination cursor or exceeded the round safety limit.")
          }
          let page = try await graph.page(url: url)
          guard version == epoch else { throw CancellationError() }
          round.visited.insert(fingerprint)
          round.messages += round.working.ingest(page.value, cycleStart: now)
          if let next = page.nextLink {
            _ = try GraphClient.checkedURL(next)
            round.nextURL = next
            round.retryAfter = nil
            try await store.savePending(round)
            if version != epoch {
              try await store.reset()
              throw CancellationError()
            }
            continue
          }
          guard let cursor = page.deltaLink else {
            throw FocusFailure.invalid("Graph did not finish its delta round.")
          }
          _ = try GraphClient.checkedURL(cursor)
          try Task.checkCancellation()
          guard version == epoch else { throw CancellationError() }
          round.working.commit(cursor: cursor, at: round.cycleStart)
          try await store.save(round.working)
          if version != epoch {
            try await store.reset()
            throw CancellationError()
          }
          try await store.clearPending()
          guard version == epoch else { throw CancellationError() }
          return SyncOutcome(
            messages: round.baselineOnly ? [] : round.messages, baselineOnly: round.baselineOnly,
            checkedAt: round.cycleStart)
        }
        // No event is emitted until all pages finish; the next poll resumes this checkpoint.
        return nil
      } catch FocusFailure.cursorExpired where recovery == 0 {
        try await store.reset()
        state = SyncState(account: account)
        continue
      } catch {
        if case FocusFailure.throttled(let seconds) = error {
          round.retryAfter = Date().addingTimeInterval(seconds)
          if version == epoch {
            try await store.savePending(round)
            if version != epoch { try await store.reset() }
          }
        }
        throw error
      }
    }
    throw FocusFailure.cursorExpired
  }
  public func reset() async throws {
    epoch += 1
    try await store.reset()
  }
}
public struct RetryPolicy: Sendable {
  public private(set) var failures = 0
  public init() {}
  public mutating func success() { failures = 0 }
  public mutating func delay(error: Error, interval: Double) -> Double {
    failures = min(8, failures + 1)
    if case FocusFailure.throttled(let seconds) = error { return max(interval, seconds) }
    return min(900, max(interval, 5 * pow(2, Double(failures - 1))))
  }
}
public actor PollCoordinator {
  private var loop: Task<Void, Never>?
  private var generation = 0
  private var configuration: (Bool, Double)?
  private let check: @Sendable () async -> Result<Void, Error>
  public init(check: @escaping @Sendable () async -> Result<Void, Error>) { self.check = check }
  public func configure(enabled: Bool, interval: Double, force: Bool = false) async {
    if !force, let configuration, configuration.0 == enabled, configuration.1 == interval,
      loop != nil || !enabled
    {
      return
    }
    configuration = (enabled, interval)
    generation += 1
    let version = generation
    let old = loop
    loop = nil
    old?.cancel()
    await old?.value
    guard enabled, generation == version else { return }
    loop = Task {
      defer { if self.generation == version { self.loop = nil } }
      var retries = RetryPolicy()
      while !Task.isCancelled {
        let result = await check()
        if Task.isCancelled { return }
        let wait: Double
        switch result {
        case .success:
          retries.success()
          wait = interval
        case .failure(let error):
          if error as? FocusFailure == .authenticationRequired { return }
          wait = retries.delay(error: error, interval: interval)
        }
        do { try await Task.sleep(nanoseconds: UInt64(min(wait, 86400) * 1_000_000_000)) } catch {
          return
        }
      }
    }
  }
  public func stop() async { await configure(enabled: false, interval: 30) }
}
