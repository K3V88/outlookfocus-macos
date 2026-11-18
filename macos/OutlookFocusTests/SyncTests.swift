import XCTest

@testable import OutlookFocusCore

final class SyncTests: XCTestCase {
  var folder: URL!
  var store: SyncStore!
  let start = Date(timeIntervalSince1970: 1_800_000_000)
  let cursor =
    "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta?$deltatoken=test"
  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "outlookfocus-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    store = SyncStore(url: folder.appendingPathComponent("test.sync.json"))
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
  func testBaselineNewMailDuplicatesAndModifications() async throws {
    let old = MailRecord(id: "old", received: start.addingTimeInterval(-3600))
    let fresh = MailRecord(id: "new", received: start.addingTimeInterval(5))
    let modified = MailRecord(
      id: "old", received: start.addingTimeInterval(-3600), importance: "high")
    let graph = FakeDelta([
      .success(DeltaPage(value: [old], deltaLink: cursor)),
      .success(DeltaPage(value: [fresh, modified, fresh], deltaLink: cursor)),
      .success(DeltaPage(value: [fresh], deltaLink: cursor)),
    ])
    let engine = SyncEngine(graph: graph, store: store)
    let baseline = try await engine.synchronize(account: "test", now: start)
    XCTAssertTrue(baseline!.baselineOnly)
    XCTAssertTrue(baseline!.messages.isEmpty)
    let next = try await engine.synchronize(account: "test", now: start.addingTimeInterval(30))
    XCTAssertEqual(next!.messages.map(\.id), ["new"])
    let duplicate = try await engine.synchronize(account: "test", now: start.addingTimeInterval(60))
    XCTAssertTrue(duplicate!.messages.isEmpty)
  }
  func testDeletedAndOldMovedMailNeverFocus() async throws {
    try await store.save(
      SyncState(account: "test", cursor: cursor, baseline: true, lastCheck: start, seen: [:]))
    let graph = FakeDelta([
      .success(
        DeltaPage(
          value: [
            MailRecord(id: "moved", received: start.addingTimeInterval(-1000)),
            MailRecord(id: "removed", received: nil, removed: true),
          ], deltaLink: cursor))
    ])
    let outcome = try await SyncEngine(graph: graph, store: store).synchronize(
      account: "test", now: start.addingTimeInterval(30))
    XCTAssertTrue(outcome!.messages.isEmpty)
  }
  func testPaginationAndPersistenceAcrossEngineRestart() async throws {
    let next =
      "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta?$skiptoken=next"
    let graph = FakeDelta([
      .success(DeltaPage(value: [MailRecord(id: "one", received: start)], nextLink: next)),
      .success(DeltaPage(value: [MailRecord(id: "two", received: start)], deltaLink: cursor)),
    ])
    let first = try await SyncEngine(graph: graph, store: store).synchronize(
      account: "test", now: start)
    XCTAssertTrue(first!.messages.isEmpty)
    let saved = try await store.load(account: "test")
    XCTAssertEqual(saved?.seen.count, 2)
    XCTAssertEqual(saved?.cursor, cursor)
    let fresh = MailRecord(id: "three", received: start.addingTimeInterval(10))
    let outcome = try await SyncEngine(
      graph: FakeDelta([.success(DeltaPage(value: [fresh], deltaLink: cursor))]), store: store
    ).synchronize(account: "test", now: start.addingTimeInterval(30))
    XCTAssertEqual(outcome!.messages.map(\.id), ["three"])
  }
  func testNetworkFailureDoesNotCommitOrEmitPartialRound() async throws {
    try await store.save(
      SyncState(account: "test", cursor: cursor, baseline: true, lastCheck: start))
    let fresh = MailRecord(id: "new", received: start.addingTimeInterval(5))
    let next =
      "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta?$skiptoken=next"
    let graph = FakeDelta([
      .success(DeltaPage(value: [fresh], nextLink: next)), .failure(FocusFailure.http(500)),
    ])
    let engine = SyncEngine(graph: graph, store: store)
    do {
      _ = try await engine.synchronize(account: "test", now: start.addingTimeInterval(30))
      XCTFail("expected failure")
    } catch {}
    let saved = try await store.load(account: "test")
    XCTAssertNil(saved?.seen["new"])
    await graph.append(.success(DeltaPage(value: [fresh], deltaLink: cursor)))
    let retry = try await engine.synchronize(account: "test", now: start.addingTimeInterval(60))
    XCTAssertEqual(retry!.messages.map(\.id), ["new"])
  }
  func testExpiredCursorRebuildsBaselineWithoutOldFocus() async throws {
    try await store.save(
      SyncState(account: "test", cursor: cursor, baseline: true, lastCheck: start))
    let graph = FakeDelta([
      .failure(FocusFailure.cursorExpired),
      .success(
        DeltaPage(
          value: [MailRecord(id: "unknown", received: start.addingTimeInterval(10))],
          deltaLink: cursor)),
    ])
    let result = try await SyncEngine(graph: graph, store: store).synchronize(
      account: "test", now: start.addingTimeInterval(30))
    XCTAssertTrue(result!.baselineOnly)
    XCTAssertTrue(result!.messages.isEmpty)
  }
  func testConcurrentSynchronizationsCannotOverlap() async throws {
    let graph = FakeDelta([.success(DeltaPage(value: [], deltaLink: cursor))], delay: 30_000_000)
    let engine = SyncEngine(graph: graph, store: store)
    async let one = engine.synchronize(account: "test", now: start)
    async let two = engine.synchronize(account: "test", now: start)
    let results = try await [one, two]
    XCTAssertEqual(results.compactMap { $0 }.count, 1)
    let count = await graph.count()
    XCTAssertEqual(count, 1)
  }
  func testAccountChangeRequiresFreshBaseline() async throws {
    try await store.save(
      SyncState(account: "other", cursor: cursor, baseline: true, lastCheck: start))
    let graph = FakeDelta([
      .success(
        DeltaPage(
          value: [MailRecord(id: "new", received: start.addingTimeInterval(5))], deltaLink: cursor))
    ])
    let outcome = try await SyncEngine(graph: graph, store: store).synchronize(
      account: "test", now: start.addingTimeInterval(30))
    XCTAssertTrue(outcome!.baselineOnly)
  }
  func testRepeatedPaginationCursorRejected() async throws {
    let graph = FakeDelta([
      .success(DeltaPage(value: [], nextLink: GraphClient.initialURL.absoluteString))
    ])
    do {
      _ = try await SyncEngine(graph: graph, store: store).synchronize(account: "test", now: start)
      XCTFail("accepted repeated cursor")
    } catch {}
  }
  func testResetDuringInflightSyncCannotRestoreDeletedMetadata() async throws {
    let graph = FakeDelta([.success(DeltaPage(value: [], deltaLink: cursor))], delay: 30_000_000)
    let engine = SyncEngine(graph: graph, store: store)
    async let run = engine.synchronize(account: "test", now: start)
    try await Task.sleep(nanoseconds: 5_000_000)
    try await engine.reset()
    do {
      _ = try await run
      XCTFail("Expected cancellation after reset")
    } catch is CancellationError {}
    let state = try await store.load(account: "test")
    XCTAssertNil(state)
  }
  func testThrottledRoundPersistsRetryDeadlineAcrossRestart() async throws {
    let graph = FakeDelta([.failure(FocusFailure.throttled(120))])
    let engine = SyncEngine(graph: graph, store: store)
    do {
      _ = try await engine.synchronize(account: "test", now: start)
      XCTFail("Expected throttle")
    } catch {}
    let pending = try await store.loadPending(account: "test")
    XCTAssertNotNil(pending?.retryAfter)
    let replacement = FakeDelta([.success(DeltaPage(value: [], deltaLink: cursor))])
    do {
      _ = try await SyncEngine(graph: replacement, store: store).synchronize(
        account: "test", now: start)
      XCTFail("Retried before Retry-After")
    } catch {}
    let count = await replacement.count()
    XCTAssertEqual(count, 0)
  }
  func testLargeBaselineResumesAfterBoundedPageBudgetWithoutEmittingOldMail() async throws {
    var pages: [Result<DeltaPage, Error>] = []
    for index in 0..<21 {
      let next =
        index < 20
        ? "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta?$skiptoken=page\(index+1)"
        : nil
      pages.append(
        .success(
          DeltaPage(
            value: [MailRecord(id: "baseline-\(index)", received: start.addingTimeInterval(-100))],
            nextLink: next, deltaLink: next == nil ? cursor : nil)))
    }
    let graph = FakeDelta(pages)
    let first = try await SyncEngine(graph: graph, store: store).synchronize(
      account: "test", now: start)
    XCTAssertNil(first)
    let checkpoint = try await store.loadPending(account: "test")
    XCTAssertNotNil(checkpoint)
    let completed = try await SyncEngine(graph: graph, store: store).synchronize(
      account: "test", now: start.addingTimeInterval(30))
    XCTAssertTrue(completed!.baselineOnly)
    XCTAssertTrue(completed!.messages.isEmpty)
    let final = try await store.load(account: "test")
    XCTAssertEqual(final?.seen.count, 21)
    let cleared = try await store.loadPending(account: "test")
    XCTAssertNil(cleared)
  }
}
