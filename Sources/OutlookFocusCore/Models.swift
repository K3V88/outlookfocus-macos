import Foundation

public enum FocusMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case desktop, chrome, smart, notificationOnly, disabled
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .desktop: return "Outlook Desktop"
    case .chrome: return "Outlook in Chrome"
    case .smart: return "Smart Mode"
    case .notificationOnly: return "Notification Only"
    case .disabled: return "Disabled"
    }
  }
}
public enum FocusTarget: String, Codable, Sendable { case desktop, chrome }
public struct Preferences: Codable, Equatable, Sendable {
  public var enabled = false
  public var automaticFocus = true
  public var notifications = false
  public var launchOutlook = false
  public var openWebIfMissing = false
  public var onlyWhenNotFrontmost = true
  public var importantOnly = false
  public var pollInterval = 30
  public var cooldown: Double = 60
  public var mode = FocusMode.smart
  public var fallback = FocusTarget.desktop
  public var quietEnabled = false
  public var quietStart = 22 * 60
  public var quietEnd = 8 * 60
  public var clientID = ""
  public var tenant = "common"
  public var preferredURL = "https://outlook.office.com/mail/"
  public var onboardingComplete = false
  public init() {}
  public mutating func validate() {
    if ![15, 30, 60, 120, 300].contains(pollInterval) { pollInterval = 30 }
    cooldown = cooldown.isFinite ? min(600, max(0, cooldown)) : 60
    quietStart = min(1439, max(0, quietStart))
    quietEnd = min(1439, max(0, quietEnd))
    if !WebDestination.isAllowed(preferredURL) { preferredURL = "https://outlook.office.com/mail/" }
    if tenant.range(of: "^[A-Za-z0-9.-]{1,253}$", options: .regularExpression) == nil {
      tenant = "common"
    }
  }
}
public enum WebDestination {
  public static let hosts: Set<String> = [
    "outlook.office.com", "outlook.live.com", "outlook.office365.com", "outlook.cloud.microsoft",
  ]
  public static func isAllowed(_ value: String) -> Bool {
    guard let u = URL(string: value), u.scheme == "https", let h = u.host,
      hosts.contains(h.lowercased()), u.user == nil, u.password == nil,
      u.port == nil || u.port == 443
    else { return false }
    return true
  }
}
public enum FocusFailure: Error, LocalizedError, Equatable {
  case invalid(String)
  case authenticationRequired
  case throttled(Double)
  case cursorExpired
  case http(Int)
  case unavailable(String)
  public var errorDescription: String? {
    switch self {
    case .invalid(let s), .unavailable(let s): return s
    case .authenticationRequired:
      return "Microsoft session expired or consent is required. Reconnect your account."
    case .throttled(let delay): return "Microsoft Graph requested a pause of \(Int(delay)) seconds."
    case .cursorExpired:
      return "The mailbox synchronization cursor expired; a fresh baseline is required."
    case .http(let status):
      return "Microsoft returned HTTP \(status). Check connectivity and account permissions."
    }
  }
}
public enum InternetDate {
  public static func parse(_ text: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = f.date(from: text) { return date }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: text)
  }
  public static func string(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
