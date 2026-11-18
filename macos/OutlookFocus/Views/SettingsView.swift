import OutlookFocusCore
import SwiftUI

struct SettingsView: View {
  @ObservedObject var model: AppModel
  private let intervals = [15, 30, 60, 120, 300]
  var body: some View {
    TabView {
      Form {
        Section("General") {
          Toggle("Enable OutlookFocus monitoring", isOn: $model.preferences.enabled)
          Toggle(
            "Launch at Login",
            isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
          Toggle("Automatically switch focus", isOn: $model.preferences.automaticFocus)
          Toggle("Show local notifications", isOn: $model.preferences.notifications)
          Toggle("Open Outlook when closed", isOn: $model.preferences.launchOutlook)
          Toggle("Open Outlook Web when no tab exists", isOn: $model.preferences.openWebIfMissing)
        }
        Section("Focus destination") {
          Picker("Destination", selection: $model.preferences.mode) {
            ForEach(FocusMode.allCases) { Text($0.title).tag($0) }
          }
          Picker("Smart fallback", selection: $model.preferences.fallback) {
            Text("Desktop").tag(FocusTarget.desktop)
            Text("Chrome").tag(FocusTarget.chrome)
          }
          Picker("Preferred Outlook Web", selection: $model.preferences.preferredURL) {
            Text("Microsoft 365 (cloud.microsoft)").tag("https://outlook.cloud.microsoft/mail/")
            Text("Microsoft 365").tag("https://outlook.office.com/mail/")
            Text("Outlook.com").tag("https://outlook.live.com/mail/")
            Text("Office 365").tag("https://outlook.office365.com/mail/")
          }
        }
        Text("The app stays in the menu bar. Closing this window does not stop monitoring.").font(
          .caption
        ).foregroundStyle(.secondary)
      }.tabItem { Label("General", systemImage: "gearshape") }
      Form {
        Section("Microsoft account") {
          TextField("Application (client) ID", text: $model.preferences.clientID).disabled(
            model.accountLabel != nil || model.connecting)
          TextField(
            "Tenant (common supports personal and work/school)", text: $model.preferences.tenant
          ).disabled(model.accountLabel != nil || model.connecting)
          LabeledContent("Account", value: model.accountLabel ?? "Not connected")
          HStack {
            Button(model.connecting ? "Connecting…" : "Connect Microsoft Account") {
              Task { await model.connect() }
            }.disabled(model.connecting || model.accountLabel != nil)
            Button("Disconnect & Delete Local Session") { Task { await model.disconnect() } }
              .disabled(model.connecting)
          }
          Text(
            "Register your own public-client Entra app with redirect URI msauth.com.k3v88.OutlookFocus://auth and delegated Mail.ReadBasic. No client secret. Some organizations require administrator approval."
          ).font(.caption).textSelection(.enabled)
        }
        if let error = model.lastError {
          Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
        Section("Inbox synchronization") {
          Picker("Polling interval", selection: $model.preferences.pollInterval) {
            ForEach(intervals, id: \.self) { Text("\($0) seconds").tag($0) }
          }
          LabeledContent(
            "Last successful check", value: model.lastCheck?.formatted() ?? "Not yet checked")
          HStack {
            Button("Synchronize Now") { Task { _ = await model.checkMailbox() } }.disabled(
              model.accountLabel == nil)
            Button("Reset Baseline") { Task { await model.resetSynchronization() } }.disabled(
              model.accountLabel == nil)
          }
          Text(
            "A first sync or reset establishes a baseline; existing messages do not trigger focus. Polling is not instant delivery."
          ).font(.caption).foregroundStyle(.secondary)
        }
      }.tabItem { Label("Monitoring", systemImage: "envelope") }
      Form {
        Section("Focus behavior") {
          Toggle(
            "Only activate when another app is frontmost",
            isOn: $model.preferences.onlyWhenNotFrontmost)
          Toggle(
            "Only automatically activate for high-importance emails",
            isOn: $model.preferences.importantOnly)
          HStack {
            Text("Activation cooldown")
            Slider(value: $model.preferences.cooldown, in: 0...600, step: 15)
            Text("\(Int(model.preferences.cooldown)) s").monospacedDigit().frame(width: 55)
          }
          Text(
            "Existing Outlook applications and tabs are always preferred. Manual focus buttons bypass quiet hours and cooldown. No keystrokes or private automation APIs are used."
          ).font(.caption).foregroundStyle(.secondary)
        }
        Section("Quiet hours — local time") {
          Toggle("Enable quiet hours", isOn: $model.preferences.quietEnabled)
          DatePicker(
            "Start", selection: timeBinding($model.preferences.quietStart),
            displayedComponents: .hourAndMinute)
          DatePicker(
            "End", selection: timeBinding($model.preferences.quietEnd),
            displayedComponents: .hourAndMinute)
          Text(
            "Overnight ranges are supported. Equal start/end means quiet all day. macOS notification and foreground policies still apply."
          ).font(.caption).foregroundStyle(.secondary)
        }
      }.tabItem { Label("Behavior", systemImage: "scope") }
      Form {
        Section("Diagnostics") {
          LabeledContent("Outlook installed", value: model.installed ? "Yes" : "No")
          LabeledContent("Outlook running", value: model.running ? "Yes" : "No")
          LabeledContent(
            "Native bridge",
            value: model.bridgeReady ? "Listening (user-only socket)" : "Unavailable")
          LabeledContent(
            "Chrome extension",
            value: model.connectedChrome > 0
              ? "Connected (\(model.connectedChrome))" : "Disconnected")
          LabeledContent(
            "Graph session",
            value: model.accountLabel != nil ? "Connected; see last sync" : "Not connected")
          LabeledContent("Last check", value: model.lastCheck?.formatted() ?? "Never")
          LabeledContent("Last email", value: model.lastMail?.formatted() ?? "None detected")
          LabeledContent("Last activation", value: model.lastActivation?.formatted() ?? "None")
          Text(model.activationStatus).font(.caption)
          if let error = model.lastError {
            Text(error).foregroundStyle(.red).textSelection(.enabled)
          }
        }
        HStack {
          Button("Test Desktop Activation") { Task { await model.focus(.desktop) } }
          Button("Test Chrome Activation") { Task { await model.focus(.chrome) } }
        }
        Button("Open Setup Assistant") { model.openOnboarding?() }
        Text(
          "Chrome needs its extension and registered native host. Real Microsoft sign-in requires your app registration; credentials are never provided by this project."
        ).font(.caption).foregroundStyle(.secondary)
      }.tabItem { Label("Diagnostics", systemImage: "stethoscope") }
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
        let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
        minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
      })
  }
}
