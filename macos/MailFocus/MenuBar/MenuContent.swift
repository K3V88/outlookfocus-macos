import SwiftUI

struct MenuContent: View {
  @ObservedObject var model: AppModel
  var body: some View {
    Text("MailFocus · Apple Mail").font(.headline)
    Text(model.status)
    if let account = model.accountLabel { Text(account) }
    if let last = model.lastCheck {
      Text("Last check: \(last.formatted(date: .omitted, time: .shortened))")
    }
    Divider()
    Toggle("Monitor Infomaniak Inbox", isOn: $model.preferences.enabled)
    Button("Focus Apple Mail") { Task { await model.focusMail() } }
    Button("Check for New Mail") { Task { _ = await model.checkMailbox() } }
    Divider()
    Button("Settings…") { model.openSettings?() }.keyboardShortcut(",")
    Button("Setup Assistant…") { model.openOnboarding?() }
    Button("Quit MailFocus") { NSApp.terminate(nil) }.keyboardShortcut("q")
  }
}
