import AppKit
import OutlookFocusCore

@MainActor final class OutlookActivator {
  private var launches: [String: Task<NSRunningApplication, Error>] = [:]
  static let outlookID = "com.microsoft.Outlook"
  static let chromeID = "com.google.Chrome"
  var outlookURL: URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.outlookID)
  }
  var outlookRunning: Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: Self.outlookID).isEmpty
  }
  var chromeRunning: Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: Self.chromeID).isEmpty
  }
  func activateDesktop(launchIfClosed: Bool, onlyWhenNotFrontmost: Bool = true) async throws {
    if let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.outlookID)
      .first
    {
      if running.isActive && onlyWhenNotFrontmost { return }
      guard running.activate(options: [.activateAllWindows]) else {
        throw FocusFailure.unavailable("macOS did not grant Outlook foreground activation.")
      }
      return
    }
    guard launchIfClosed else {
      throw FocusFailure.unavailable(
        "Outlook is closed. Enable ‘Open Outlook when closed’ or launch it yourself.")
    }
    guard let url = outlookURL else {
      throw FocusFailure.unavailable("Microsoft Outlook is not installed.")
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    _ = try await launch(url: url, id: Self.outlookID, configuration: configuration)
  }
  func launchChromeIfNeeded(allowed: Bool) async throws {
    if chromeRunning { return }
    guard allowed else {
      throw FocusFailure.unavailable(
        "Google Chrome is not running and automatic opening is disabled.")
    }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.chromeID) else {
      throw FocusFailure.unavailable("Google Chrome is not installed.")
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    _ = try await launch(url: url, id: Self.chromeID, configuration: configuration)
  }
  private func launch(url: URL, id: String, configuration: NSWorkspace.OpenConfiguration)
    async throws -> NSRunningApplication
  {
    if let task = launches[id] { return try await task.value }
    let task = Task {
      try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
    launches[id] = task
    defer { launches.removeValue(forKey: id) }
    return try await task.value
  }
  func activateChrome(onlyWhenNotFrontmost: Bool = true) throws {
    guard
      let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: Self.chromeID)
        .first
    else { throw FocusFailure.unavailable("Google Chrome is not running.") }
    if chrome.isActive && onlyWhenNotFrontmost { return }
    guard chrome.activate(options: [.activateAllWindows]) else {
      throw FocusFailure.unavailable("macOS did not grant Chrome foreground activation.")
    }
  }
}
