import AppKit
import MailFocusCore
import ServiceManagement
import SwiftUI

@MainActor final class AppModel: ObservableObject {
  @Published var preferences: Preferences {
    didSet {
      guard initialized, !normalizingPreferences else { return }
      var validated = preferences
      validated.validate()
      if validated != preferences {
        normalizingPreferences = true
        preferences = validated
        normalizingPreferences = false
      }
      try? preferenceStore.save(preferences)
      if oldValue.enabled != preferences.enabled { resetBaseline() }
      Task { await reconfigure() }
    }
  }
  @Published var mailAddress: String {
    didSet {
      saveEmailIfValid()
      resetBaseline()
      accountLabel = nil
      Task { await reconfigure() }
    }
  }
  @Published var savedMailAddress = ""
  @Published var accountLabel: String?
  @Published var connecting = false
  @Published var lastCheck: Date?
  @Published var lastMail: Date?
  @Published var lastActivation: Date?
  @Published var inboxMessageCount = 0
  @Published var newMessageCount = 0
  @Published var lastError: String?
  @Published var monitoringError: String?
  @Published var status = "Connect your Infomaniak account in Apple Mail"
  @Published var activationStatus = "No activation attempted"
  @Published var loginEnabled = false
  @Published var installed = false
  @Published var running = false
  var openSettings: (() -> Void)?
  var openOnboarding: (() -> Void)?
  private let preferenceStore = PreferenceStore()
  private let accountStore = MailAccountStore()
  private let activator = AppleMailActivator()
  private let monitor = AppleMailMonitor()
  private var tracker = AppleMailInboxTracker()
  private var initialized = false
  private var normalizingPreferences = false
  private var checking = false
  private var generation = 0
  private var activationHistory = FocusActivationHistory()
  private var observations: [NSObjectProtocol] = []
  private var monitoringActivity: NSObjectProtocol?
  private lazy var poller = PollCoordinator { [weak self] in
    guard let self else { return .success(()) }
    return await self.checkMailbox()
  }
  init() {
    PreferenceStore.migrateLegacySettings()
    var saved = preferenceStore.load()
    // This version uses Apple Mail exclusively, including for migrated settings.
    saved.mode = .desktop
    saved.importantOnly = false
    preferences = saved
    var restoredEmail = ""
    var restoreError: String?
    do { restoredEmail = try accountStore.loadOrMigrate() ?? "" } catch {
      restoreError = error.localizedDescription
    }
    mailAddress = restoredEmail
    savedMailAddress = restoredEmail
    lastError = restoreError
  }
  func start() {
    guard !initialized else { return }
    initialized = true
    updateAvailability()
    loginEnabled = SMAppService.mainApp.status == .enabled
    let center = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
    ] {
      observations.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          Task { @MainActor in self?.updateAvailability() }
        })
    }
    observations.append(
      center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
        [weak self] _ in
        Task { @MainActor in
          guard let self else { return }
          self.resetBaseline()
          await self.reconfigure()
        }
      })
    Task { await reconfigure() }
  }
  func stop() {
    saveEmailIfValid()
    if let monitoringActivity { ProcessInfo.processInfo.endActivity(monitoringActivity) }
    monitoringActivity = nil
    generation += 1
    for observation in observations {
      NSWorkspace.shared.notificationCenter.removeObserver(observation)
    }
    observations.removeAll()
    Task { await poller.stop() }
  }
  func saveEmailIfValid() {
    guard MailAccountStore.normalizedEmail(mailAddress) != nil else { return }
    do {
      let saved = try accountStore.save(mailAddress)
      savedMailAddress = saved
      UserDefaults.standard.set(saved, forKey: "appleMailAddress")
    } catch { lastError = "Could not save email address: \(error.localizedDescription)" }
  }
  private func updateAvailability() {
    installed = activator.mailURL != nil
    running = activator.mailRunning
  }
  private func resetBaseline() {
    generation += 1
    tracker = AppleMailInboxTracker()
    lastCheck = nil
    lastMail = nil
  }
  func reconfigure() async {
    let address = mailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    let shouldMonitor = preferences.enabled && MailAccountStore.normalizedEmail(address) != nil
    if shouldMonitor, monitoringActivity == nil {
      monitoringActivity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep,
        reason: "Monitor incoming email in Apple Mail")
    } else if !shouldMonitor, let activity = monitoringActivity {
      ProcessInfo.processInfo.endActivity(activity)
      monitoringActivity = nil
    }
    status =
      address.isEmpty
      ? "Enter your Infomaniak email address"
      : preferences.enabled
        ? lastCheck == nil ? "Connecting to Apple Mail…" : "Monitoring Apple Mail Inbox"
        : "Monitoring paused"
    await poller.configure(
      enabled: shouldMonitor, interval: Double(preferences.pollInterval))
  }
  func connect() async {
    guard !connecting else { return }
    connecting = true
    defer { connecting = false }
    saveEmailIfValid()
    resetBaseline()
    _ = await checkMailbox(allowLaunch: true)
  }
  func resetSynchronization() async {
    resetBaseline()
    _ = await checkMailbox()
  }
  func checkMailbox(allowLaunch: Bool = false) async -> Result<Void, Error> {
    guard !checking else { return .success(()) }
    let address = mailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    guard address.contains("@"), !address.contains("\n"), !address.contains("\r") else {
      let error = FocusFailure.invalid(
        "Enter the Infomaniak email address configured in Apple Mail.")
      lastError = error.localizedDescription
      return .failure(error)
    }
    checking = true
    defer {
      checking = false
      UserDefaults.standard.set(
        [
          "checkedAt": Date().timeIntervalSince1970,
          "status": status,
          "error": lastError ?? "",
          "inboxCount": inboxMessageCount,
          "newCount": newMessageCount,
          "activation": activationStatus,
          "successfulCheck": lastCheck?.timeIntervalSince1970 ?? 0,
        ], forKey: "monitoringDiagnostics")
    }
    let version = generation
    do {
      if !activator.mailRunning {
        guard allowLaunch || preferences.launchOutlook else {
          throw FocusFailure.unavailable(
            "Apple Mail is closed. Open Mail or enable ‘Open Apple Mail when closed’.")
        }
        try await activator.openMailInBackground()
      }
      let snapshot = try await monitor.snapshot(email: address)
      try Task.checkCancellation()
      guard version == generation else { return .success(()) }
      let newMessages = tracker.ingest(account: snapshot.accountID, messages: snapshot.messages)
      inboxMessageCount = snapshot.messages.count
      newMessageCount = newMessages.count
      accountLabel = snapshot.accountName
      lastCheck = Date()
      lastError = nil
      monitoringError = nil
      status = preferences.enabled ? "Monitoring Apple Mail Inbox" : "Connected — monitoring paused"
      if !newMessages.isEmpty {
        lastMail = newMessages.map(\.receivedAt).max()
        let decision = FocusPolicy.decide(
          preferences: preferences,
          availability: FocusAvailability(
            desktopInstalled: installed, desktopRunning: activator.mailRunning,
            chromeConnected: false, webTabOpen: false),
          important: true, lastAttempt: activationHistory.lastAutomaticActivation)
        activationStatus = decision.reason
        if decision.target != nil { await focusMail(manual: false) }
      }
      updateAvailability()
      return .success(())
    } catch is CancellationError {
      return .success(())
    } catch {
      guard version == generation else { return .success(()) }
      lastError = error.localizedDescription
      monitoringError = lastError
      status = "Mail check failed — see Monitoring"
      return .failure(error)
    }
  }
  func focusMail(manual: Bool = true) async {
    do {
      try await activator.activateDesktop(
        launchIfClosed: preferences.launchOutlook,
        onlyWhenNotFrontmost: preferences.onlyWhenNotFrontmost)
      lastActivation = Date()
      activationHistory.recordSuccess(manual: manual)
      activationStatus = "Apple Mail activated"
      lastError = nil
    } catch {
      activationStatus = "Activation failed"
      lastError = error.localizedDescription
    }
    updateAvailability()
  }
  func setLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      loginEnabled = SMAppService.mainApp.status == .enabled
      if SMAppService.mainApp.status == .requiresApproval {
        lastError = "Approve MailFocus in System Settings → General → Login Items."
      }
    } catch { lastError = error.localizedDescription }
  }
}
