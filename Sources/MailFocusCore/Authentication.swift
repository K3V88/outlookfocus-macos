import CryptoKit
import Foundation
import Security

public struct TokenRecord: Codable, Sendable {
  public var accessToken: String
  public var refreshToken: String
  public var expiresAt: Date
  public var accountID: String
  public var displayName: String
  public init(
    accessToken: String, refreshToken: String, expiresAt: Date, accountID: String,
    displayName: String
  ) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
    self.accountID = accountID
    self.displayName = displayName
  }
}
public struct HTTPResult: Sendable {
  public let data: Data
  public let status: Int
  public let headers: [String: String]
  public init(data: Data, status: Int, headers: [String: String] = [:]) {
    self.data = data
    self.status = status
    self.headers = headers
  }
}
public protocol HTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> HTTPResult
}
private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}
public struct URLSessionTransport: HTTPTransport {
  private let session: URLSession
  public init() {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 30
    c.timeoutIntervalForResource = 60
    c.httpCookieStorage = nil
    session = URLSession(configuration: c, delegate: NoRedirect(), delegateQueue: nil)
  }
  public func send(_ request: URLRequest) async throws -> HTTPResult {
    let (data, response) = try await session.data(for: request)
    guard let h = response as? HTTPURLResponse else {
      throw FocusFailure.unavailable("No HTTP response.")
    }
    var headers: [String: String] = [:]
    for (k, v) in h.allHeaderFields {
      headers[String(describing: k).lowercased()] = String(describing: v)
    }
    return HTTPResult(data: data, status: h.statusCode, headers: headers)
  }
}
public struct PKCE: Sendable {
  public let verifier: String
  public let state: String
  public var challenge: String { Self.base64(Data(SHA256.hash(data: Data(verifier.utf8)))) }
  public init() throws {
    verifier = try Self.random()
    state = try Self.random()
  }
  public init(verifier: String, state: String) {
    self.verifier = verifier
    self.state = state
  }
  private static func random() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw FocusFailure.unavailable("Secure random generation failed.")
    }
    return base64(Data(bytes))
  }
  public static func base64(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
      of: "/", with: "_"
    ).replacingOccurrences(of: "=", with: "")
  }
}
public actor MicrosoftAuth {
  public static let redirectURI = "msauth.com.k3v88.MailFocus://auth"
  public static let scopes =
    "openid profile offline_access https://graph.microsoft.com/Mail.ReadBasic"
  private let transport: any HTTPTransport
  private let cache: any TokenCaching
  private var current: TokenRecord?
  private var clientID = ""
  private var tenant = "common"
  private var refresh: Task<TokenRecord, Error>?
  public init(
    transport: any HTTPTransport = URLSessionTransport(),
    cache: any TokenCaching = KeychainTokenCache()
  ) {
    self.transport = transport
    self.cache = cache
  }
  public func configure(clientID: String, tenant: String) async throws {
    if self.clientID != clientID {
      refresh?.cancel()
      refresh = nil
      self.clientID = clientID
      let requestedID = clientID
      let saved =
        UUID(uuidString: requestedID) == nil ? nil : try await cache.load(clientID: requestedID)
      if self.clientID == requestedID { current = saved }
    }
    self.tenant = tenant
  }
  public func session() -> TokenRecord? { current }
  public func authorizationURL(pkce: PKCE) throws -> URL {
    guard UUID(uuidString: clientID) != nil,
      tenant.range(of: "^[A-Za-z0-9.-]{1,253}$", options: .regularExpression) != nil
    else {
      throw FocusFailure.invalid(
        "Enter a valid Entra application client ID and tenant before connecting.")
    }
    var c = URLComponents(
      string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/authorize")!
    c.queryItems = [
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
      URLQueryItem(name: "response_mode", value: "query"),
      URLQueryItem(name: "scope", value: Self.scopes),
      URLQueryItem(name: "code_challenge", value: pkce.challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "state", value: pkce.state),
      URLQueryItem(name: "prompt", value: "select_account"),
    ]
    return c.url!
  }
  public func complete(callback: URL, pkce: PKCE) async throws -> TokenRecord {
    guard callback.scheme?.lowercased() == URL(string: Self.redirectURI)!.scheme?.lowercased(),
      callback.host == "auth"
    else { throw FocusFailure.invalid("Unexpected authentication callback.") }
    let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func item(_ name: String) -> String? {
      let values = items.filter { $0.name == name }
      return values.count == 1 ? values[0].value : nil
    }
    guard item("state") == pkce.state else {
      throw FocusFailure.invalid("Authentication state mismatch. Please reconnect.")
    }
    guard let code = item("code"), !code.isEmpty else { throw FocusFailure.authenticationRequired }
    return try await exchange(
      ["grant_type": "authorization_code", "code": code, "code_verifier": pkce.verifier],
      previous: nil)
  }
  private func exchange(_ fields: [String: String], previous: TokenRecord?) async throws
    -> TokenRecord
  {
    let configuredID = clientID
    let configuredTenant = tenant
    var request = URLRequest(
      url: URL(string: "https://login.microsoftonline.com/\(configuredTenant)/oauth2/v2.0/token")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    var fields = fields
    fields["client_id"] = configuredID
    fields["redirect_uri"] = Self.redirectURI
    fields["scope"] = Self.scopes
    var components = URLComponents()
    components.queryItems = fields.sorted { $0.key < $1.key }.map {
      URLQueryItem(name: $0.key, value: $0.value)
    }
    request.httpBody = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
      .data(using: .utf8)
    let response = try await transport.send(request)
    try Task.checkCancellation()
    guard response.status == 200 else { throw FocusFailure.authenticationRequired }
    guard let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
      let access = json["access_token"] as? String,
      let refreshToken = (json["refresh_token"] as? String) ?? previous?.refreshToken,
      let expires = json["expires_in"] as? Double, !access.isEmpty, !refreshToken.isEmpty
    else { throw FocusFailure.authenticationRequired }
    var account = previous?.accountID ?? ""
    var name = previous?.displayName ?? "Microsoft account"
    // ID-token claims are display/cache labels only; no authorization is based on them.
    if let idToken = json["id_token"] as? String {
      let parts = idToken.split(separator: ".")
      if parts.count == 3 {
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
          .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        if let data = Data(base64Encoded: payload),
          let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
          account = (claims["sub"] as? String) ?? account
          name = (claims["preferred_username"] as? String) ?? (claims["name"] as? String) ?? name
        }
      }
    }
    guard !account.isEmpty, configuredID == clientID else {
      throw FocusFailure.authenticationRequired
    }
    let token = TokenRecord(
      accessToken: access, refreshToken: refreshToken,
      expiresAt: Date().addingTimeInterval(max(0, expires)), accountID: account,
      displayName: String(name.prefix(200)))
    try await cache.save(token, clientID: configuredID)
    current = token
    return token
  }
  public func accessToken(forceRefresh: Bool = false) async throws -> String {
    guard let token = current else { throw FocusFailure.authenticationRequired }
    if !forceRefresh && token.expiresAt.timeIntervalSinceNow > 90 { return token.accessToken }
    if let refresh { return try await refresh.value.accessToken }
    let task = Task {
      try await self.exchange(
        ["grant_type": "refresh_token", "refresh_token": token.refreshToken], previous: token)
    }
    refresh = task
    defer { refresh = nil }
    do { return try await task.value.accessToken } catch {
      if error as? FocusFailure == .authenticationRequired { current = nil }
      throw error
    }
  }
  public func disconnect() async throws {
    refresh?.cancel()
    refresh = nil
    current = nil
    try await cache.removeAll()
  }
  public func accountKey() -> String? {
    guard let current else { return nil }
    return PKCE.base64(Data(SHA256.hash(data: Data((clientID + ":" + current.accountID).utf8))))
  }
}
