import Darwin
import Foundation
import Security

public struct AppPaths {
  public let directory: URL
  public init(directory: URL? = nil) {
    self.directory =
      directory
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/MailFocus", isDirectory: true)
  }
  public var socket: URL { directory.appendingPathComponent("bridge.sock") }
  public var sync: URL { directory.appendingPathComponent("mailbox.sync.json") }
  public var origins: URL { directory.appendingPathComponent("allowed-origins.json") }
  public func prepare() throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let a = try FileManager.default.attributesOfItem(atPath: directory.path)
    guard a[.type] as? FileAttributeType == .typeDirectory,
      (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
    else {
      throw FocusFailure.invalid(
        "MailFocus data directory must be a real directory owned by this user.")
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }
}
public protocol TokenCaching: Sendable {
  func load(clientID: String) async throws -> TokenRecord?
  func save(_ token: TokenRecord, clientID: String) async throws
  func remove(clientID: String) async throws
  func removeAll() async throws
}
public actor KeychainTokenCache: TokenCaching {
  private let service = "com.k3v88.MailFocus.oauth"
  public init() {}
  private func query(_ id: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: id, kSecAttrSynchronizable as String: false,
    ]
  }
  public func load(clientID: String) throws -> TokenRecord? {
    var q = query(clientID)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var output: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &output)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = output as? Data else {
      throw FocusFailure.unavailable("Keychain could not read the account cache (\(status)).")
    }
    return try JSONDecoder().decode(TokenRecord.self, from: data)
  }
  public func save(_ token: TokenRecord, clientID: String) throws {
    let data = try JSONEncoder().encode(token)
    let q = query(clientID)
    let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var add = q
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
        throw FocusFailure.unavailable("Keychain could not save the session.")
      }
    } else if status != errSecSuccess {
      throw FocusFailure.unavailable("Keychain could not update the session.")
    }
  }
  public func removeAll() throws {
    let q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
    ]
    let status = SecItemDelete(q as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw FocusFailure.unavailable("Keychain could not remove the app session cache.")
    }
  }
  public func remove(clientID: String) throws {
    let status = SecItemDelete(query(clientID) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw FocusFailure.unavailable("Keychain could not remove the session.")
    }
  }
}
public actor SyncStore {
  private let url: URL
  private var pendingURL: URL { url.appendingPathExtension("pending") }
  public init(url: URL) { self.url = url }
  public func load(account: String) throws -> SyncState? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let value = try JSONDecoder().decode(SyncState.self, from: Data(contentsOf: url))
    return value.account == account ? value : nil
  }
  public func loadPending(account: String) throws -> PendingRound? {
    guard FileManager.default.fileExists(atPath: pendingURL.path) else { return nil }
    let value = try JSONDecoder().decode(PendingRound.self, from: Data(contentsOf: pendingURL))
    return value.account == account ? value : nil
  }
  private func write<T: Encodable>(_ value: T, to file: URL) throws {
    try JSONEncoder().encode(value).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
  public func save(_ state: SyncState) throws { try write(state, to: url) }
  public func savePending(_ state: PendingRound) throws { try write(state, to: pendingURL) }
  public func clearPending() throws {
    if FileManager.default.fileExists(atPath: pendingURL.path) {
      try FileManager.default.removeItem(at: pendingURL)
    }
  }
  public func reset() throws {
    for file in [url, pendingURL] {
      if FileManager.default.fileExists(atPath: file.path) {
        try FileManager.default.removeItem(at: file)
      }
    }
  }
}
public struct PreferenceStore {
  /// Import the previous app's local settings once, without replacing newer settings.
  /// The old identifier is retained only to locate that preferences domain.
  public static func migrateLegacySettings(
    defaults: UserDefaults = .standard, legacyDomain: String = "com.k3v88.OutlookFocus"
  ) {
    guard !defaults.bool(forKey: "mailFocusMigrationComplete") else { return }
    let legacy = defaults.persistentDomain(forName: legacyDomain) ?? [:]
    for key in ["preferences", "appleMailAddress"] where defaults.object(forKey: key) == nil {
      if let value = legacy[key] { defaults.set(value, forKey: key) }
    }
    defaults.set(true, forKey: "mailFocusMigrationComplete")
  }
  private let defaults: UserDefaults
  public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
  public func load() -> Preferences {
    guard let data = defaults.data(forKey: "preferences"),
      var p = try? JSONDecoder().decode(Preferences.self, from: data)
    else { return Preferences() }
    p.validate()
    return p
  }
  public func save(_ prefs: Preferences) throws {
    var p = prefs
    p.validate()
    defaults.set(try JSONEncoder().encode(p), forKey: "preferences")
  }
}

/// Store the selected mailbox independently of deferred UserDefaults writes and UI drafts.
public struct MailAccountStore: Sendable {
  private struct Account: Codable { let email: String }
  public let url: URL
  public init(url: URL = AppPaths().directory.appendingPathComponent("mail-account.json")) {
    self.url = url
  }
  public static func normalizedEmail(_ input: String) -> String? {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = value.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
      !value.contains(where: { $0.isWhitespace || $0.isNewline }),
      value.rangeOfCharacter(from: .controlCharacters) == nil,
      !value.contains("<"), !value.contains(">")
    else { return nil }
    return value
  }
  public func load() throws -> String? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let account = try JSONDecoder().decode(Account.self, from: Data(contentsOf: url))
    guard let email = Self.normalizedEmail(account.email) else {
      throw FocusFailure.invalid(
        "The saved email address is invalid. Enter it again in Monitoring.")
    }
    return email
  }
  @discardableResult public func save(_ input: String) throws -> String {
    guard let email = Self.normalizedEmail(input) else {
      throw FocusFailure.invalid("Enter a complete email address before saving.")
    }
    try AppPaths(directory: url.deletingLastPathComponent()).prepare()
    try JSONEncoder().encode(Account(email: email)).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return email
  }
  public func loadOrMigrate(defaults: UserDefaults = .standard) throws -> String? {
    if let saved = try load() { return saved }
    guard let old = defaults.string(forKey: "appleMailAddress"),
      Self.normalizedEmail(old) != nil
    else { return nil }
    return try save(old)
  }
}
