import XCTest

@testable import MailFocusCore

final class SmokeTests: XCTestCase {
  func testDefaultMonitoringIsOptIn() { XCTAssertFalse(Preferences().enabled) }
}
