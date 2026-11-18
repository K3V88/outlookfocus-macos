import OutlookFocusCore
import SwiftUI

struct OnboardingView: View {
  @ObservedObject var model: AppModel
  let finished: () -> Void
  @State private var step = 0
  private let titles = [
    "Welcome to OutlookFocus", "Find Outlook Desktop", "Connect Microsoft", "Connect Chrome",
    "Choose your destination", "Test Outlook Desktop", "Test Outlook in Chrome",
    "Enable monitoring", "You’re ready",
  ]
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Image(systemName: "envelope.badge").font(.system(size: 38)).foregroundStyle(.blue)
        Spacer()
        Text("STEP \(step+1) OF 9").font(.caption).foregroundStyle(.secondary)
      }
      Text(titles[step]).font(.largeTitle.bold())
      Group {
        switch step {
        case 0:
          Text(
            "A private menu-bar companion that detects newly received Inbox mail and brings the right Outlook destination forward. You control monitoring, automatic focus, quiet hours and cooldown."
          )
        case 1:
          Label(
            model.installed
              ? "Microsoft Outlook is installed."
              : "Outlook Desktop is not installed. Chrome mode can still be used.",
            systemImage: model.installed ? "checkmark.circle" : "info.circle")
        case 2:
          VStack(alignment: .leading) {
            Text(
              "Enter your own Entra client ID in Settings → Monitoring. Use public-client PKCE and delegated Mail.ReadBasic. No password or client secret is stored."
            )
            Button("Open Settings") { model.openSettings?() }
            Button(model.connecting ? "Connecting…" : "Connect Microsoft Account") {
              Task { await model.connect() }
            }.disabled(model.connecting)
            Text(model.accountLabel ?? "Not connected — you can configure this later.").font(
              .caption)
          }
        case 3:
          VStack(alignment: .leading) {
            Text(
              "Build and load chrome-extension/dist in chrome://extensions, copy its real extension ID, then run the native-host installer with that ID. Keep this app running."
            )
            Label(
              model.connectedChrome > 0
                ? "Chrome extension connected"
                : "Chrome extension not connected (desktop-only mode still works)",
              systemImage: model.connectedChrome > 0 ? "checkmark.circle" : "info.circle")
          }
        case 4:
          Picker("Focus destination", selection: $model.preferences.mode) {
            ForEach(FocusMode.allCases) { Text($0.title).tag($0) }
          }
        case 5:
          VStack(alignment: .leading) {
            Toggle("Allow Outlook to open when closed", isOn: $model.preferences.launchOutlook)
            Button("Test Desktop Activation") { Task { await model.focus(.desktop) } }
            Text(model.activationStatus)
          }
        case 6:
          VStack(alignment: .leading) {
            Toggle(
              "Allow Outlook Web to open when missing", isOn: $model.preferences.openWebIfMissing)
            Button("Test Chrome Activation") { Task { await model.focus(.chrome) } }
            Text(model.activationStatus)
          }
        case 7:
          VStack(alignment: .leading) {
            Toggle("Monitor my Inbox", isOn: $model.preferences.enabled)
            Text(
              "The first successful check creates a baseline without focusing old mail. Subsequent checks run every \(model.preferences.pollInterval) seconds. A connected Microsoft account is required."
            )
          }
        default:
          Text(
            "OutlookFocus stays in the menu bar. You can reopen Settings and this assistant at any time. Enable Launch at Login after installing the app in Applications if desired."
          )
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      if let error = model.lastError { Text(error).font(.caption).foregroundStyle(.red) }
      Spacer()
      HStack {
        Button("Back") { step -= 1 }.disabled(step == 0)
        Spacer()
        Button(step == 8 ? "Finish Setup" : "Continue") {
          if step < 8 {
            step += 1
          } else {
            model.preferences.onboardingComplete = true
            finished()
          }
        }.buttonStyle(.borderedProminent)
      }
    }.padding(32).frame(minWidth: 580, minHeight: 430)
  }
}
