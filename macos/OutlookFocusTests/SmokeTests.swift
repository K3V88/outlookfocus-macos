import XCTest

@testable import OutlookFocusCore

final class SmokeTests: XCTestCase {
  func testDefaultMonitoringIsOptIn() { XCTAssertFalse(Preferences().enabled) }
}
