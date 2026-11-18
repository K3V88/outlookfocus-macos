import AppKit
import MailFocusCore

@MainActor final class AppleMailActivator {
  static let mailID = "com.apple.mail"
  var mailURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.mailID) }
  var mailRunning: Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: Self.mailID).isEmpty
  }
  func activateDesktop(launchIfClosed: Bool, onlyWhenNotFrontmost: Bool = true) async throws {
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.mailID).first {
      if app.isActive && onlyWhenNotFrontmost { return }
      app.unhide()
      guard app.activate(options: [.activateAllWindows]) else {
        throw FocusFailure.unavailable("macOS did not grant Apple Mail foreground activation.")
      }
    } else {
      guard launchIfClosed else {
        throw FocusFailure.unavailable(
          "Apple Mail is closed. Open it or enable ‘Open Apple Mail when closed’.")
      }
      try await openMail(activate: true)
    }
  }
  func openMailInBackground() async throws { try await openMail(activate: false) }
  private func openMail(activate: Bool) async throws {
    guard let url = mailURL else { throw FocusFailure.unavailable("Apple Mail is not installed.") }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = activate
    _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
  }
}

struct AppleMailSnapshot: Sendable {
  let accountID: String
  let accountName: String
  let messages: [AppleMailMessage]
}

final class AppleMailMonitor: @unchecked Sendable {
  // Keep scripting off the UI thread and serialize all Mail Apple events.
  private let queue = DispatchQueue(label: "com.k3v88.MailFocus.apple-mail")
  func snapshot(email: String) async throws -> AppleMailSnapshot {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do { continuation.resume(returning: try Self.readSnapshot(email: email)) } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
  private static func readSnapshot(email: String) throws -> AppleMailSnapshot {
    let escaped = email.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
      of: "\"", with: "\\\"")
    let source = """
      with timeout of 30 seconds
        tell application id "com.apple.mail"
          set selectedAccount to missing value
          ignoring case
            repeat with candidate in every account
              if email addresses of candidate contains "\(escaped)" then
                set selectedAccount to contents of candidate
                exit repeat
              end if
            end repeat
          end ignoring
          if selectedAccount is missing value then error "No Apple Mail account matches this email address. Add your Infomaniak account in Mail → Add Account first." number -10001
          if enabled of selectedAccount is false then error "This Apple Mail account is disabled. Enable it in Mail → Settings → Accounts." number -10002
          set inboxBox to mailbox "INBOX" of selectedAccount
          set messageIDs to id of every message of inboxBox
          set receivedDates to date received of every message of inboxBox
          return {id of selectedAccount, name of selectedAccount, messageIDs, receivedDates}
        end tell
      end timeout
      """
    guard let script = NSAppleScript(source: source) else {
      throw FocusFailure.invalid("Could not prepare Apple Mail monitoring.")
    }
    var details: NSDictionary?
    let result = script.executeAndReturnError(&details)
    if let details {
      let number = (details[NSAppleScript.errorNumber] as? NSNumber)?.intValue
      if number == -1743 {
        throw FocusFailure.unavailable(
          "Allow MailFocus to control Mail in System Settings → Privacy & Security → Automation, then click Connect Apple Mail again."
        )
      }
      if number == -1712 || number == -609 {
        throw FocusFailure.unavailable(
          "Apple Mail is not responding to Inbox checks. MailFocus will retry automatically. If this continues, quit and reopen Apple Mail, then click Connect Apple Mail. Your email address stays saved."
        )
      }
      let message = details[NSAppleScript.errorMessage] as? String ?? "Apple Mail did not respond."
      throw FocusFailure.unavailable(message)
    }
    guard result.numberOfItems == 4,
      let account = result.atIndex(1)?.stringValue,
      let name = result.atIndex(2)?.stringValue,
      let ids = result.atIndex(3), let dates = result.atIndex(4),
      ids.numberOfItems == dates.numberOfItems
    else {
      throw FocusFailure.unavailable("Apple Mail returned an incomplete Inbox snapshot. Try again.")
    }
    var messages: [AppleMailMessage] = []
    if ids.numberOfItems > 0 {
      for index in 1...ids.numberOfItems {
        guard let id = ids.atIndex(index), let date = dates.atIndex(index)?.dateValue else {
          throw FocusFailure.unavailable(
            "Apple Mail is synchronizing the Inbox. Try again shortly.")
        }
        messages.append(AppleMailMessage(id: String(id.int32Value), receivedAt: date))
      }
    }
    return AppleMailSnapshot(accountID: account, accountName: name, messages: messages)
  }
}
