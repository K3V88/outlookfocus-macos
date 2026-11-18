import AppKit
import Network
import OutlookFocusCore
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor final class AppModel: ObservableObject {
  @Published var preferences: Preferences {
    didSet {
      guard initialized else { return }
      preferences.validate()
      try? preferenceStore.save(preferences)
      if preferences.notifications && !oldValue.notifications { requestNotifications() }
      Task { await reconfigure() }
      broadcastStatus()
    }
  }
  @Published var accountLabel: String?
  @Published var connecting = false
  @Published var lastCheck: Date?
  @Published var lastMail: Date?
  @Published var lastActivation: Date?
  @Published var lastError: String?
  @Published var status = "Configure your Microsoft account"
  @Published var activationStatus = "No activation attempted"
  @Published var bridgeReady = false
  @Published var connectedChrome = 0
  @Published var loginEnabled = false
  @Published var installed = false
  @Published var running = false
  var openSettings: (() -> Void)?
  var openOnboarding: (() -> Void)?
  private let preferenceStore = PreferenceStore()
  private let paths = AppPaths()
  private let auth: MicrosoftAuth
  private let engine: SyncEngine
  private let bridge: BridgeServer
  private let activator = OutlookActivator()
  private let presenter = AuthenticationPresenter()
  private var initialized = false
  private var clients: [UUID: Bool] = [:]
  private var events = EventCache()
  private var pending: [String: (CheckedContinuation<Void, Error>, Task<Void, Never>)] = [:]
  private var connectionWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
  private var observations: [NSObjectProtocol] = []
  private let network = NWPathMonitor()
  private var hadNetwork = false
  private lazy var poller = PollCoordinator { [weak self] in
    guard let self else { return .success(()) }
    return await self.checkMailbox()
  }
  init() {
    preferences = preferenceStore.load()
    let service = MicrosoftAuth()
    auth = service
    engine = SyncEngine(
      graph: GraphClient(token: { force in try await service.accessToken(forceRefresh: force) }),
      store: SyncStore(url: paths.sync))
    bridge = BridgeServer(paths: paths)
  }
  func start() {
    guard !initialized else { return }
    initialized = true
    installed = activator.outlookURL != nil
    running = activator.outlookRunning
    loginEnabled = SMAppService.mainApp.status == .enabled
    do {
      try paths.prepare()
      bridge.onMessage = { [weak self] id, message in
        Task { @MainActor in self?.receive(message, client: id) }
      }
      bridge.onDisconnect = { [weak self] id in
        Task { @MainActor in
          self?.clients.removeValue(forKey: id)
          self?.connectedChrome = self?.clients.count ?? 0
        }
      }
      try bridge.start()
      bridgeReady = true
    } catch {
      lastError = error.localizedDescription
      status = "Bridge unavailable; monitoring not started"
      return
    }
    let center = NSWorkspace.shared.notificationCenter
    observations.append(
      center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
        [weak self] _ in Task { await self?.poller.stop() }
      })
    observations.append(
      center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
        [weak self] _ in Task { await self?.resumeMonitoring() }
      })
    network.pathUpdateHandler = { [weak self] path in
      Task { @MainActor in
        guard let self else { return }
        let available = path.status == .satisfied
        if available && !self.hadNetwork { await self.resumeMonitoring() }
        self.hadNetwork = available
      }
    }
    network.start(queue: DispatchQueue(label: "OutlookFocus.network"))
    for name in [
      NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
    ] {
      observations.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          Task { @MainActor in
            guard let self else { return }
            self.installed = self.activator.outlookURL != nil
            self.running = self.activator.outlookRunning
          }
        })
    }
    Task { await reconfigure() }
  }
  func resumeMonitoring() async {
    await poller.stop()
    await reconfigure()
  }
  func reconfigure() async {
    let p = preferences
    do {
      try await auth.configure(clientID: p.clientID, tenant: p.tenant)
      guard preferences.clientID == p.clientID else { return }
      accountLabel = await auth.session()?.displayName
      if let key = await auth.accountKey(),
        let saved = try? await SyncStore(url: paths.sync).load(account: key)
      {
        lastCheck = saved.lastCheck
      }
      if accountLabel == nil {
        status = "Connect a Microsoft account"
      } else if !preferences.enabled {
        status = "Monitoring paused"
      } else {
        status = "Monitoring Inbox"
      }
      await poller.configure(
        enabled: preferences.enabled && accountLabel != nil,
        interval: Double(preferences.pollInterval))
      broadcastStatus()
    } catch { lastError = error.localizedDescription }
  }
  func connect() async {
    guard !connecting else { return }
    connecting = true
    defer { connecting = false }
    do {
      try await auth.configure(clientID: preferences.clientID, tenant: preferences.tenant)
      let pkce = try PKCE()
      let url = try await auth.authorizationURL(pkce: pkce)
      let callback = try await presenter.authenticate(url: url)
      let token = try await auth.complete(callback: callback, pkce: pkce)
      accountLabel = token.displayName
      lastError = nil
      await reconfigure()
    } catch { lastError = error.localizedDescription }
  }
  func disconnect() async {
    preferences.enabled = false
    await poller.stop()
    presenter.cancel()
    do {
      try await auth.disconnect()
      try await engine.reset()
      accountLabel = nil
      lastCheck = nil
      lastMail = nil
      preferences.enabled = false
      status = "Account disconnected"
      lastError = nil
      broadcastStatus()
    } catch { lastError = error.localizedDescription }
  }
  func resetSynchronization() async {
    do {
      await poller.stop()
      try await engine.reset()
      lastCheck = nil
      status = "Baseline will be rebuilt without focusing old mail"
      await reconfigure()
    } catch { lastError = error.localizedDescription }
  }
  func checkMailbox() async -> Result<Void, Error> {
    guard let key = await auth.accountKey() else {
      return .failure(FocusFailure.authenticationRequired)
    }
    do {
      if lastCheck == nil { status = "Establishing Inbox baseline…" }
      guard let outcome = try await engine.synchronize(account: key) else { return .success(()) }
      try Task.checkCancellation()
      lastCheck = outcome.checkedAt
      lastError = nil
      status =
        outcome.baselineOnly
        ? "Inbox baseline established"
        : preferences.enabled ? "Monitoring Inbox" : "Monitoring paused"
      if !outcome.messages.isEmpty {
        lastMail =
          outcome.messages.compactMap { $0.receivedDateTime.flatMap { InternetDate.parse($0) } }
          .max() ?? Date()
        var payload = Payload()
        payload.count = outcome.messages.count
        payload.lastEmail = lastMail.map { InternetDate.string($0) }
        broadcast(Envelope(.mailNew, payload: payload))
        let important = outcome.messages.contains { $0.importance == "high" }
        if preferences.notifications, preferences.enabled,
          !FocusPolicy.isQuiet(preferences, at: Date()), preferences.mode != .disabled,
          !preferences.importantOnly || important
        {
          showNotification()
        }
        let decision = FocusPolicy.decide(
          preferences: preferences, availability: availability, important: important,
          lastAttempt: lastActivation)
        activationStatus = decision.reason
        if let target = decision.target { await focus(target, manual: false) }
      }
      broadcastStatus()
      return .success(())
    } catch is CancellationError { return .success(()) } catch {
      lastError = error.localizedDescription
      if error as? FocusFailure == .authenticationRequired {
        accountLabel = nil
        status = "Reconnect Microsoft account"
      }
      broadcastStatus()
      return .failure(error)
    }
  }
  var availability: FocusAvailability {
    FocusAvailability(
      desktopInstalled: activator.outlookURL != nil, desktopRunning: activator.outlookRunning,
      chromeConnected: !clients.isEmpty, webTabOpen: clients.values.contains(true))
  }
  @discardableResult func focus(
    _ target: FocusTarget, manual: Bool = true, openWebOverride: Bool? = nil
  ) async -> Bool {
    var succeeded = false
    let openWeb = openWebOverride ?? preferences.openWebIfMissing
    lastActivation = Date()
    activationStatus = "Activating \(target.rawValue)…"
    do {
      if target == .desktop {
        try await activator.activateDesktop(
          launchIfClosed: preferences.launchOutlook,
          onlyWhenNotFrontmost: preferences.onlyWhenNotFrontmost)
      } else {
        try await activator.launchChromeIfNeeded(allowed: openWeb || manual)
        try await waitForChrome()
        guard let client = clients.first(where: { $0.value })?.key ?? clients.keys.first else {
          throw FocusFailure.unavailable("Chrome extension is disconnected.")
        }
        var payload = Payload()
        payload.target = .chrome
        payload.openIfMissing = openWeb
        payload.preferredURL = preferences.preferredURL
        payload.manual = manual
        let request = Envelope(.focusRequest, payload: payload)
        try await withCheckedThrowingContinuation { continuation in
          let timeout = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if !Task.isCancelled {
              self.finish(
                request.id,
                result: .failure(
                  FocusFailure.unavailable("Chrome did not acknowledge focus within 10 seconds.")))
            }
          }
          pending[request.id] = (continuation, timeout)
          do { try bridge.send(request, to: client) } catch {
            finish(request.id, result: .failure(error))
          }
        }
        try activator.activateChrome(onlyWhenNotFrontmost: preferences.onlyWhenNotFrontmost)
      }
      activationStatus = "\(target == .desktop ? "Outlook Desktop" : "Outlook Web") activated"
      lastError = nil
      succeeded = true
    } catch {
      activationStatus = "Activation failed"
      lastError = error.localizedDescription
    }
    installed = activator.outlookURL != nil
    running = activator.outlookRunning
    return succeeded
  }
  func openWeb() async { await focus(.chrome, openWebOverride: true) }
  private func waitForChrome() async throws {
    if !clients.isEmpty { return }
    let id = UUID()
    try await withCheckedThrowingContinuation { continuation in
      connectionWaiters[id] = continuation
      Task {
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        if let waiter = self.connectionWaiters.removeValue(forKey: id) {
          waiter.resume(
            throwing: FocusFailure.unavailable(
              "Install the Chrome extension and native host, then click Retry Connection in its popup."
            ))
        }
      }
    }
  }
  private func finish(_ id: String, result: Result<Void, Error>) {
    guard let (continuation, timeout) = pending.removeValue(forKey: id) else { return }
    timeout.cancel()
    continuation.resume(with: result)
  }
  private func receive(_ message: Envelope, client: UUID) {
    guard events.accept(message.id) else { return }
    switch message.type {
    case .hello:
      clients[client] = false
      connectedChrome = clients.count
      for (_, waiter) in connectionWaiters { waiter.resume() }
      connectionWaiters.removeAll()
      var payload = Payload()
      payload.connected = true
      try? bridge.send(Envelope(.connectionStatus, payload: payload), to: client)
      sendStatus(to: client)
    case .connectionStatus:
      clients[client] = message.payload.webTabOpen ?? false
      connectedChrome = clients.count
    case .preferencesGet: sendStatus(to: client)
    case .preferencesUpdate:
      if let mode = message.payload.mode { preferences.mode = mode }
      if let enabled = message.payload.enabled { preferences.enabled = enabled }
      if let automatic = message.payload.automaticFocus { preferences.automaticFocus = automatic }
      if let open = message.payload.openIfMissing { preferences.openWebIfMissing = open }
      if let url = message.payload.preferredURL, WebDestination.isAllowed(url) {
        preferences.preferredURL = url
      }
      sendStatus(to: client)
    case .focusRequest:
      if let target = message.payload.target {
        Task {
          let success = await focus(target, manual: true)
          var p = Payload()
          p.success = success
          p.target = target
          if !success { p.error = lastError ?? "Activation failed." }
          try? bridge.send(Envelope(.focusResult, id: message.id, payload: p), to: client)
        }
      }
    case .focusResult:
      finish(
        message.id,
        result: message.payload.success == true
          ? .success(())
          : .failure(
            FocusFailure.unavailable(
              message.payload.error ?? "Chrome could not activate Outlook Web.")))
    case .appSettings: openSettings?()
    case .ping: try? bridge.send(Envelope(.pong, id: message.id), to: client)
    default: break
    }
  }
  private func sendStatus(to id: UUID) {
    var p = Payload()
    p.enabled = preferences.enabled
    p.automaticFocus = preferences.automaticFocus
    p.mode = preferences.mode
    p.openIfMissing = preferences.openWebIfMissing
    p.preferredURL = preferences.preferredURL
    try? bridge.send(Envelope(.preferencesUpdate, payload: p), to: id)
    var s = Payload()
    s.monitoring = preferences.enabled && accountLabel != nil
    s.lastCheck = lastCheck.map { InternetDate.string($0) }
    s.lastEmail = lastMail.map { InternetDate.string($0) }
    try? bridge.send(Envelope(.monitoringStatus, payload: s), to: id)
  }
  private func broadcast(_ message: Envelope) {
    for id in clients.keys { try? bridge.send(message, to: id) }
  }
  private func broadcastStatus() { for id in clients.keys { sendStatus(to: id) } }
  func setLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      loginEnabled = SMAppService.mainApp.status == .enabled
      if SMAppService.mainApp.status == .requiresApproval {
        lastError = "Approve OutlookFocus in System Settings → General → Login Items."
      }
    } catch { lastError = error.localizedDescription }
  }
  private func requestNotifications() {
    Task {
      do {
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [
          .alert, .sound,
        ])
        if !granted {
          lastError =
            "Notifications are not permitted. Enable OutlookFocus in System Settings → Notifications."
        }
      } catch { lastError = "Notifications are unavailable. Check System Settings." }
    }
  }
  private func showNotification() {
    let content = UNMutableNotificationContent()
    content.title = "New Outlook mail"
    content.body = "New mail is available in your Inbox."
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    ) { _ in }
  }
  func stop() {
    network.cancel()
    bridge.stop()
    for observation in observations {
      NSWorkspace.shared.notificationCenter.removeObserver(observation)
    }
    Task { await poller.stop() }
  }
}
