import Foundation

public struct FocusAvailability: Sendable {
  public var desktopInstalled: Bool
  public var desktopRunning: Bool
  public var chromeConnected: Bool
  public var webTabOpen: Bool
  public init(desktopInstalled: Bool, desktopRunning: Bool, chromeConnected: Bool, webTabOpen: Bool)
  {
    self.desktopInstalled = desktopInstalled
    self.desktopRunning = desktopRunning
    self.chromeConnected = chromeConnected
    self.webTabOpen = webTabOpen
  }
}
public struct FocusDecision: Equatable, Sendable {
  public let target: FocusTarget?
  public let reason: String
  public init(_ target: FocusTarget?, _ reason: String) {
    self.target = target
    self.reason = reason
  }
}
public enum FocusPolicy {
  public static func isQuiet(_ prefs: Preferences, at date: Date, calendar: Calendar = .current)
    -> Bool
  {
    guard prefs.quietEnabled else { return false }
    let c = calendar.dateComponents([.hour, .minute], from: date)
    let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
    if prefs.quietStart == prefs.quietEnd { return true }
    return prefs.quietStart < prefs.quietEnd
      ? minute >= prefs.quietStart && minute < prefs.quietEnd
      : minute >= prefs.quietStart || minute < prefs.quietEnd
  }
  public static func decide(
    preferences p: Preferences, availability a: FocusAvailability, important: Bool,
    lastAttempt: Date?, now: Date = Date(), calendar: Calendar = .current
  ) -> FocusDecision {
    guard p.enabled && p.automaticFocus else {
      return FocusDecision(nil, "Automatic focus is disabled.")
    }
    guard p.mode != .disabled && p.mode != .notificationOnly else {
      return FocusDecision(nil, "The selected mode does not change focus.")
    }
    guard !isQuiet(p, at: now, calendar: calendar) else {
      return FocusDecision(nil, "Quiet hours are active.")
    }
    guard !p.importantOnly || important else {
      return FocusDecision(nil, "No high-importance message in this batch.")
    }
    if let lastAttempt, now.timeIntervalSince(lastAttempt) < p.cooldown {
      return FocusDecision(nil, "Activation cooldown is active.")
    }
    func allowed(_ target: FocusTarget) -> FocusDecision {
      if target == .desktop {
        return (a.desktopRunning || (a.desktopInstalled && p.launchOutlook))
          ? FocusDecision(.desktop, "Use Apple Mail.")
          : FocusDecision(nil, "Apple Mail is unavailable or automatic launching is disabled.")
      }
      return a.chromeConnected && (a.webTabOpen || p.openWebIfMissing)
        ? FocusDecision(.chrome, "Use the connected Chrome extension.")
        : p.openWebIfMissing
          ? FocusDecision(.chrome, "Chrome may be launched, then its extension must connect.")
          : FocusDecision(nil, "No connected Outlook Web tab and automatic opening is disabled.")
    }
    switch p.mode {
    case .desktop: return allowed(.desktop)
    case .chrome: return allowed(.chrome)
    case .smart:
      if a.desktopRunning { return allowed(.desktop) }
      if a.chromeConnected && a.webTabOpen { return allowed(.chrome) }
      return allowed(p.fallback)
    case .disabled, .notificationOnly: return FocusDecision(nil, "No activation.")
    }
  }
}

/// Manual tests and failed attempts must not suppress subsequent incoming mail.
public struct FocusActivationHistory: Sendable {
  public private(set) var lastAutomaticActivation: Date?
  public init() {}
  public mutating func recordSuccess(manual: Bool, at date: Date = Date()) {
    if !manual { lastAutomaticActivation = date }
  }
}
