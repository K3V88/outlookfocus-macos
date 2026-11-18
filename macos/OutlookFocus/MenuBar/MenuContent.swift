import OutlookFocusCore
import SwiftUI

struct MenuContent: View {
  @ObservedObject var model: AppModel
  var body: some View {
    Text("OutlookFocus").font(.headline)
    Text(model.status)
    if let account = model.accountLabel { Text(account) }
    if let last = model.lastCheck {
      Text("Last check: \(last.formatted(date:.omitted,time:.shortened))")
    }
    if let last = model.lastMail {
      Text("Last new mail: \(last.formatted(date:.omitted,time:.shortened))")
    }
    Text("Destination: \(model.preferences.mode.title)")
    Divider()
    Toggle("Monitor Inbox", isOn: $model.preferences.enabled)
    Button("Focus Outlook Desktop") { Task { await model.focus(.desktop) } }
    Button("Focus Outlook in Chrome") { Task { await model.focus(.chrome) } }
    Button("Switch to Smart Mode") { model.preferences.mode = .smart }
    Button("Check for New Mail") { Task { _ = await model.checkMailbox() } }.disabled(
      model.accountLabel == nil)
    Divider()
    Button("Settings…") { model.openSettings?() }.keyboardShortcut(",")
    Button("Setup Assistant…") { model.openOnboarding?() }
    Button("Quit OutlookFocus") { NSApp.terminate(nil) }.keyboardShortcut("q")
  }
}
