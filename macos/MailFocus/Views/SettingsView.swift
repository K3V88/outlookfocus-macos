import MailFocusCore
import SwiftUI

struct SettingsView: View {
  @ObservedObject var model: AppModel
  @State private var selectedTab = 1
  var body: some View {
    TabView(selection: $selectedTab) {
      Form {
        Section("Apple Mail") {
          LabeledContent("Destination", value: "Apple Mail")
          Toggle("Enable Inbox monitoring", isOn: $model.preferences.enabled)
          Toggle("Automatically switch focus", isOn: $model.preferences.automaticFocus)
          Toggle("Open Apple Mail when closed", isOn: $model.preferences.launchOutlook)
          Toggle(
            "Launch at Login",
            isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
        }
        Text(
          "New mail in your selected Infomaniak Inbox brings Apple Mail forward. Mail handles account sign-in and synchronization."
        )
        .font(.caption).foregroundStyle(.secondary)
      }.tabItem { Label("General", systemImage: "gearshape") }.tag(0)
      Form {
        Section("Infomaniak account in Apple Mail") {
          TextField("Email address", text: $model.mailAddress)
            .onSubmit { model.saveEmailIfValid() }
          if model.savedMailAddress
            == model.mailAddress.trimmingCharacters(in: .whitespacesAndNewlines),
            !model.savedMailAddress.isEmpty
          {
            Label("Email saved on this Mac", systemImage: "checkmark.circle")
              .font(.caption).foregroundStyle(.secondary)
          }
          LabeledContent("Account", value: model.accountLabel ?? "Not connected")
          Button(model.connecting ? "Connecting…" : "Connect Apple Mail") {
            Task { await model.connect() }
          }.disabled(model.connecting)
          Text(
            "First add your Infomaniak email in Apple Mail → Add Account. Enter that same email address here, then allow MailFocus to control Mail when macOS asks."
          )
          .font(.caption).foregroundStyle(.secondary)
          Link(
            "Set up Infomaniak in Apple Mail",
            destination: URL(string: "https://config.infomaniak.com")!)
        }
        if let error = model.monitoringError ?? model.lastError {
          Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled)
        }
        Section("Inbox checks") {
          Picker("Polling interval", selection: $model.preferences.pollInterval) {
            ForEach([15, 30, 60, 120, 300], id: \.self) { Text("\($0) seconds").tag($0) }
          }
          LabeledContent(
            "Last successful check", value: model.lastCheck?.formatted() ?? "Not yet checked")
          HStack {
            Button("Check Now") { Task { _ = await model.checkMailbox() } }.disabled(
              model.connecting)
            Button("Reset Baseline") { Task { await model.resetSynchronization() } }.disabled(
              model.connecting)
          }
          Text(
            "The first check establishes a baseline and skips existing emails. Keep Apple Mail running and set Mail → Settings → General → Check for new messages to Automatically. MailFocus detects messages after Mail receives them."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }.tabItem { Label("Monitoring", systemImage: "envelope") }.tag(1)
      Form {
        Section("Focus behavior") {
          Toggle(
            "Only activate when another app is frontmost",
            isOn: $model.preferences.onlyWhenNotFrontmost)
          HStack {
            Text("Activation cooldown")
            Slider(value: $model.preferences.cooldown, in: 0...600, step: 15)
            Text("\(Int(model.preferences.cooldown)) s").monospacedDigit().frame(width: 55)
          }
        }
        Section("Quiet hours — local time") {
          Toggle("Enable quiet hours", isOn: $model.preferences.quietEnabled)
          DatePicker(
            "Start", selection: timeBinding($model.preferences.quietStart),
            displayedComponents: .hourAndMinute)
          DatePicker(
            "End", selection: timeBinding($model.preferences.quietEnd),
            displayedComponents: .hourAndMinute)
          Text("Equal start and end times keep quiet hours active all day.").font(.caption)
            .foregroundStyle(.secondary)
        }
      }.tabItem { Label("Behavior", systemImage: "scope") }.tag(2)
      Form {
        Section("Diagnostics") {
          LabeledContent("Apple Mail installed", value: model.installed ? "Yes" : "No")
          LabeledContent("Apple Mail running", value: model.running ? "Yes" : "No")
          LabeledContent("Status", value: model.status)
          LabeledContent("Inbox messages", value: String(model.inboxMessageCount))
          LabeledContent("New messages in last check", value: String(model.newMessageCount))
          LabeledContent("Last new email", value: model.lastMail?.formatted() ?? "None detected")
          Text(model.activationStatus).font(.caption)
          if let error = model.monitoringError ?? model.lastError {
            Text(error).foregroundStyle(.red).textSelection(.enabled)
          }
        }
        Button("Test Apple Mail Activation") { Task { await model.focusMail() } }
        Button("Open Setup Assistant") { model.openOnboarding?() }
      }.tabItem { Label("Diagnostics", systemImage: "stethoscope") }.tag(3)
    }.formStyle(.grouped).padding(12).frame(minWidth: 660, minHeight: 600)
  }
  private func timeBinding(_ minutes: Binding<Int>) -> Binding<Date> {
    Binding(
      get: {
        Calendar.current.date(
          bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0,
          of: Date()) ?? Date()
      },
      set: {
        let components = Calendar.current.dateComponents([.hour, .minute], from: $0)
        minutes.wrappedValue = (components.hour ?? 0) * 60 + (components.minute ?? 0)
      })
  }
}
