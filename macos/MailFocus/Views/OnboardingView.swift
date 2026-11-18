import SwiftUI

struct OnboardingView: View {
  @ObservedObject var model: AppModel
  let finished: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Image(systemName: "envelope.badge").font(.system(size: 38)).foregroundStyle(.blue)
      Text("Apple Mail + Infomaniak").font(.largeTitle.bold())
      Text("Bring Apple Mail forward when a new email arrives in your Infomaniak Inbox.")
      Text(
        "1. Add your Infomaniak email account in Apple Mail.\n2. Open Settings → Monitoring and enter that email address.\n3. Click Connect Apple Mail and allow access to Mail.\n4. Enable Inbox monitoring in General."
      )
      Button("Open Settings") { model.openSettings?() }
      Text(
        "Apple Mail keeps your password. MailFocus checks message identifiers and received dates, and skips existing emails on its first check."
      )
      .font(.caption).foregroundStyle(.secondary)
      Spacer()
      HStack {
        Spacer()
        Button("Done") {
          model.preferences.onboardingComplete = true
          finished()
          model.openSettings?()
        }.buttonStyle(.borderedProminent)
      }
    }.padding(32).frame(minWidth: 580, minHeight: 430)
  }
}
