import XCTest

@testable import OutlookFocusCore

actor MemoryTokens: TokenCaching {
  var value: TokenRecord?
  init(_ value: TokenRecord? = nil) { self.value = value }
  func load(clientID: String) -> TokenRecord? { value }
  func save(_ token: TokenRecord, clientID: String) { value = token }
  func remove(clientID: String) { value = nil }
  func removeAll() { value = nil }
}
actor FakeHTTP: HTTPTransport {
  var results: [HTTPResult]
  var requests: [URLRequest] = []
  init(_ results: [HTTPResult]) { self.results = results }
  func send(_ request: URLRequest) async throws -> HTTPResult {
    requests.append(request)
    guard !results.isEmpty else { throw FocusFailure.unavailable("No test response") }
    return results.removeFirst()
  }
  func count() -> Int { requests.count }
  func first() -> URLRequest? { requests.first }
}
actor FakeDelta: DeltaFetching {
  var responses: [Result<DeltaPage, Error>]
  var urls: [URL] = []
  var delay: UInt64
  init(_ responses: [Result<DeltaPage, Error>], delay: UInt64 = 0) {
    self.responses = responses
    self.delay = delay
  }
  func page(url: URL) async throws -> DeltaPage {
    urls.append(url)
    if delay > 0 { try await Task.sleep(nanoseconds: delay) }
    guard !responses.isEmpty else { throw FocusFailure.http(500) }
    return try responses.removeFirst().get()
  }
  func append(_ result: Result<DeltaPage, Error>) { responses.append(result) }
  func count() -> Int { urls.count }
}
final class CoreTests: XCTestCase {
  func testPKCERFCVector() {
    let p = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "state")
    XCTAssertEqual(p.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  }
  func testSecurePKCEIsUnique() throws {
    let a = try PKCE()
    let b = try PKCE()
    XCTAssertNotEqual(a.verifier, b.verifier)
    XCTAssertGreaterThanOrEqual(a.verifier.count, 43)
  }
  func testWebAllowlist() {
    XCTAssertTrue(WebDestination.isAllowed("https://outlook.live.com/mail/"))
    for value in [
      "http://outlook.live.com/", "https://outlook.office.com.evil.invalid/",
      "https://user@outlook.office.com/", "https://example.invalid/",
      "https://outlook.live.com:444/",
    ] { XCTAssertFalse(WebDestination.isAllowed(value)) }
  }
  func testPreferencePersistence() throws {
    let suite = "OutlookFocus-tests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = PreferenceStore(defaults: defaults)
    var p = Preferences()
    p.mode = .chrome
    p.enabled = true
    p.pollInterval = 120
    try store.save(p)
    XCTAssertEqual(store.load(), p)
  }
  func testPreferenceValidation() {
    var p = Preferences()
    p.pollInterval = 1
    p.cooldown = .infinity
    p.quietStart = -1
    p.quietEnd = 9999
    p.preferredURL = "https://evil.invalid/"
    p.validate()
    XCTAssertEqual(p.pollInterval, 30)
    XCTAssertEqual(p.cooldown, 60)
    XCTAssertEqual(p.quietStart, 0)
    XCTAssertEqual(p.quietEnd, 1439)
    XCTAssertTrue(WebDestination.isAllowed(p.preferredURL))
  }
  func testOvernightQuietHours() {
    var p = Preferences()
    p.quietEnabled = true
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(secondsFromGMT: 0)!
    func date(_ hour: Int) -> Date {
      c.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: hour))!
    }
    XCTAssertTrue(FocusPolicy.isQuiet(p, at: date(23), calendar: c))
    XCTAssertTrue(FocusPolicy.isQuiet(p, at: date(7), calendar: c))
    XCTAssertFalse(FocusPolicy.isQuiet(p, at: date(12), calendar: c))
    p.quietStart = 300
    p.quietEnd = 300
    XCTAssertTrue(FocusPolicy.isQuiet(p, at: date(12), calendar: c))
  }
  func testSameDayQuietHours() {
    var p = Preferences()
    p.quietEnabled = true
    p.quietStart = 9 * 60
    p.quietEnd = 17 * 60
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(secondsFromGMT: 0)!
    let at = c.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 10))!
    XCTAssertTrue(FocusPolicy.isQuiet(p, at: at, calendar: c))
  }
  func testSmartDestinationAndFallback() {
    var p = Preferences()
    p.enabled = true
    let both = FocusAvailability(
      desktopInstalled: true, desktopRunning: true, chromeConnected: true, webTabOpen: true)
    XCTAssertEqual(
      FocusPolicy.decide(preferences: p, availability: both, important: false, lastAttempt: nil)
        .target, .desktop)
    let web = FocusAvailability(
      desktopInstalled: true, desktopRunning: false, chromeConnected: true, webTabOpen: true)
    XCTAssertEqual(
      FocusPolicy.decide(preferences: p, availability: web, important: false, lastAttempt: nil)
        .target, .chrome)
    p.fallback = .desktop
    XCTAssertNil(
      FocusPolicy.decide(
        preferences: p,
        availability: FocusAvailability(
          desktopInstalled: true, desktopRunning: false, chromeConnected: false, webTabOpen: false),
        important: false, lastAttempt: nil
      ).target)
    p.launchOutlook = true
    XCTAssertEqual(
      FocusPolicy.decide(
        preferences: p,
        availability: FocusAvailability(
          desktopInstalled: true, desktopRunning: false, chromeConnected: false, webTabOpen: false),
        important: false, lastAttempt: nil
      ).target, .desktop)
  }
  func testCooldownAndImportance() {
    var p = Preferences()
    p.enabled = true
    p.mode = .desktop
    let a = FocusAvailability(
      desktopInstalled: true, desktopRunning: true, chromeConnected: false, webTabOpen: false)
    XCTAssertNil(
      FocusPolicy.decide(preferences: p, availability: a, important: true, lastAttempt: Date())
        .target)
    p.importantOnly = true
    XCTAssertNil(
      FocusPolicy.decide(preferences: p, availability: a, important: false, lastAttempt: nil).target
    )
    XCTAssertEqual(
      FocusPolicy.decide(preferences: p, availability: a, important: true, lastAttempt: nil).target,
      .desktop)
  }
  func testDisabledAndNotificationModesNeverFocus() {
    var p = Preferences()
    p.enabled = true
    let a = FocusAvailability(
      desktopInstalled: true, desktopRunning: true, chromeConnected: true, webTabOpen: true)
    for mode in [FocusMode.disabled, .notificationOnly] {
      p.mode = mode
      XCTAssertNil(
        FocusPolicy.decide(preferences: p, availability: a, important: true, lastAttempt: nil)
          .target)
    }
  }
  func testMissingAppsDoNotLaunchWithoutPermission() {
    var p = Preferences()
    p.enabled = true
    p.mode = .chrome
    let a = FocusAvailability(
      desktopInstalled: false, desktopRunning: false, chromeConnected: false, webTabOpen: false)
    XCTAssertNil(
      FocusPolicy.decide(preferences: p, availability: a, important: false, lastAttempt: nil).target
    )
    p.openWebIfMissing = true
    XCTAssertEqual(
      FocusPolicy.decide(preferences: p, availability: a, important: false, lastAttempt: nil)
        .target, .chrome)
  }
  func testProtocolRoundTripAndNoSensitiveFields() throws {
    var p = Payload()
    p.target = .chrome
    p.manual = true
    let e = Envelope(.focusRequest, payload: p)
    XCTAssertEqual(try Envelope.decoded(e.encoded()), e)
    var json = try JSONSerialization.jsonObject(with: e.encoded()) as! [String: Any]
    json["payload"] = ["target": "chrome", "accessToken": "must-not-cross-the-bridge"]
    XCTAssertThrowsError(try Envelope.decoded(JSONSerialization.data(withJSONObject: json)))
  }
  func testProtocolRejectsInvalidVersionAndDestination() throws {
    let e = Envelope(.ping)
    var json = try JSONSerialization.jsonObject(with: e.encoded()) as! [String: Any]
    json["v"] = 2
    XCTAssertThrowsError(try Envelope.decoded(JSONSerialization.data(withJSONObject: json)))
    var p = Payload()
    p.target = .chrome
    p.preferredURL = "https://evil.invalid"
    XCTAssertThrowsError(try Envelope(.focusRequest, payload: p).encoded())
  }
  func testDuplicateCacheIsBounded() {
    var c = EventCache(capacity: 2)
    XCTAssertTrue(c.accept("1"))
    XCTAssertFalse(c.accept("1"))
    XCTAssertTrue(c.accept("2"))
    XCTAssertTrue(c.accept("3"))
    XCTAssertTrue(c.accept("1"))
  }
  func testNativeFramingRoundTrip() throws {
    let bytes = try Envelope(.ping).encoded()
    var fds: [Int32] = [0, 0]
    XCTAssertEqual(pipe(&fds), 0)
    defer {
      close(fds[0])
      close(fds[1])
    }
    try Framing.write(bytes, fd: fds[1])
    XCTAssertEqual(try Framing.read(fd: fds[0]), bytes)
  }
  func testNativeFramingRejectsOversizedOrEmpty() {
    XCTAssertThrowsError(try Framing.encode(Data()))
    XCTAssertThrowsError(try Framing.encode(Data(repeating: 0, count: 65537)))
  }
  func testNativeFramingRejectsTruncatedBody() throws {
    var fds: [Int32] = [0, 0]
    XCTAssertEqual(pipe(&fds), 0)
    defer { close(fds[0]) }
    let bytes = Data([4, 0, 0, 0, 65, 66])
    _ = bytes.withUnsafeBytes { write(fds[1], $0.baseAddress, $0.count) }
    close(fds[1])
    XCTAssertThrowsError(try Framing.read(fd: fds[0]))
  }
  func testRetryAfterAndBackoff() {
    XCTAssertEqual(GraphClient.retryAfter("120"), 120)
    XCTAssertNil(GraphClient.retryAfter("bad"))
    var r = RetryPolicy()
    XCTAssertEqual(r.delay(error: FocusFailure.throttled(240), interval: 30), 240)
    r.success()
    XCTAssertEqual(r.delay(error: FocusFailure.http(500), interval: 30), 30)
    for _ in 0..<10 { _ = r.delay(error: FocusFailure.http(500), interval: 30) }
    XCTAssertLessThanOrEqual(r.delay(error: FocusFailure.http(500), interval: 30), 900)
  }
  func testGraphRejectsCredentialExfiltrationURL() {
    for s in [
      "http://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta",
      "https://evil.invalid/v1.0/me/messages", "https://user@graph.microsoft.com/v1.0/me/messages",
    ] { XCTAssertThrowsError(try GraphClient.checkedURL(s)) }
  }
  func testInitialQueryOnlySelectsMetadata() {
    let s = GraphClient.initialURL.absoluteString
    XCTAssertTrue(s.contains("changeType=created"))
    XCTAssertFalse(s.contains("subject"))
    XCTAssertFalse(s.contains("body"))
    XCTAssertTrue(s.contains("receivedDateTime"))
  }
  func testAuthenticationRejectsStateMismatchBeforeNetwork() async throws {
    let transport = FakeHTTP([])
    let auth = MicrosoftAuth(transport: transport, cache: MemoryTokens())
    try await auth.configure(clientID: UUID().uuidString, tenant: "common")
    let p = PKCE(verifier: "verifier", state: "expected")
    do {
      _ = try await auth.complete(
        callback: URL(string: MicrosoftAuth.redirectURI + "?code=test&state=wrong")!, pkce: p)
      XCTFail("accepted wrong state")
    } catch {}
    let count = await transport.count()
    XCTAssertEqual(count, 0)
  }
  func testAuthorizationURLUsesPKCEAndLeastPrivilege() async throws {
    let auth = MicrosoftAuth(cache: MemoryTokens())
    try await auth.configure(clientID: UUID().uuidString, tenant: "common")
    let p = try PKCE()
    let url = try await auth.authorizationURL(pkce: p)
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
    XCTAssertEqual(query.first { $0.name == "code_challenge" }?.value, p.challenge)
    XCTAssertTrue(query.first { $0.name == "scope" }!.value!.contains("Mail.ReadBasic"))
    XCTAssertFalse(url.absoluteString.contains("client_secret"))
  }
  func testExpiredTokenRefreshesAndCachesSecurely() async throws {
    let old = TokenRecord(
      accessToken: "expired-test-token", refreshToken: "test-refresh-token",
      expiresAt: Date(timeIntervalSince1970: 0), accountID: "test-account",
      displayName: "Test account")
    let cache = MemoryTokens(old)
    let http = FakeHTTP([
      HTTPResult(
        data: Data(#"{"access_token":"new-test-token","expires_in":3600}"#.utf8), status: 200)
    ])
    let auth = MicrosoftAuth(transport: http, cache: cache)
    try await auth.configure(clientID: UUID().uuidString, tenant: "common")
    async let first = auth.accessToken()
    async let second = auth.accessToken()
    let values = try await [first, second]
    XCTAssertEqual(values, ["new-test-token", "new-test-token"])
    let count = await http.count()
    XCTAssertEqual(count, 1)
    try await auth.disconnect()
    let cleared = await cache.load(clientID: "")
    XCTAssertNil(cleared)
  }
  func testGraph401RefreshesOnce() async throws {
    let page = DeltaPage(value: [], deltaLink: GraphClient.initialURL.absoluteString)
    let http = FakeHTTP([
      HTTPResult(data: Data(), status: 401),
      HTTPResult(data: try JSONEncoder().encode(page), status: 200),
    ])
    let graph = GraphClient(transport: http, token: { _ in "test-only" })
    _ = try await graph.page(url: GraphClient.initialURL)
    let count = await http.count()
    XCTAssertEqual(count, 2)
  }
  func testGraphThrottlingPreventsImmediateRetry() async throws {
    let http = FakeHTTP([HTTPResult(data: Data(), status: 429, headers: ["retry-after": "120"])])
    let graph = GraphClient(transport: http, token: { _ in "test-only" })
    for _ in 0..<2 {
      do {
        _ = try await graph.page(url: GraphClient.initialURL)
        XCTFail("expected throttle")
      } catch { guard case FocusFailure.throttled = error else { return XCTFail("wrong error") } }
    }
    let count = await http.count()
    XCTAssertEqual(count, 1)
  }
}

actor CheckCounter {
  var count = 0
  func increment() { count += 1 }
  func total() -> Int { count }
}
final class PollingTests: XCTestCase {
  func testIdenticalPreferencesDoNotRestartPolling() async throws {
    let counter = CheckCounter()
    let poller = PollCoordinator {
      await counter.increment()
      return .success(())
    }
    await poller.configure(enabled: true, interval: 30)
    try await Task.sleep(nanoseconds: 20_000_000)
    for _ in 0..<10 { await poller.configure(enabled: true, interval: 30) }
    try await Task.sleep(nanoseconds: 20_000_000)
    await poller.stop()
    let total = await counter.total()
    XCTAssertEqual(total, 1)
  }
  func testRunningDesktopDoesNotRequireLaunchServicesRegistration() {
    var p = Preferences()
    p.enabled = true
    p.mode = .desktop
    let a = FocusAvailability(
      desktopInstalled: false, desktopRunning: true, chromeConnected: false, webTabOpen: false)
    XCTAssertEqual(
      FocusPolicy.decide(preferences: p, availability: a, important: false, lastAttempt: nil)
        .target, .desktop)
  }
  func testGraphFractionalArrivalDates() {
    XCTAssertNotNil(InternetDate.parse("2026-11-18T10:30:00.1234567Z"))
  }
}

final class BridgeOwnershipTests: XCTestCase {
  func testASecondInstanceDoesNotRemoveAnActiveSocket() throws {
    let dir = URL(fileURLWithPath: "/private/tmp/of-socket-" + UUID().uuidString)
    let paths = AppPaths(directory: dir)
    try paths.prepare()
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = BridgeServer(paths: paths)
    try first.start()
    defer { first.stop() }
    let second = BridgeServer(paths: paths)
    XCTAssertThrowsError(try second.start())
    second.stop()
    XCTAssertTrue(FileManager.default.fileExists(atPath: paths.socket.path))
    let connection = try LocalSocket.connect(path: paths.socket.path)
    close(connection)
  }
}
