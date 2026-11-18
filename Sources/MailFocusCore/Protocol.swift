import Foundation

public enum MessageType: String, Codable, CaseIterable, Sendable {
  case hello
  case connectionStatus = "connection.status"
  case monitoringStatus = "monitoring.status"
  case mailNew = "mail.new"
  case focusRequest = "focus.request"
  case focusResult = "focus.result"
  case preferencesGet = "preferences.get"
  case preferencesUpdate = "preferences.update"
  case appSettings = "app.settings"
  case ping, pong
}
public struct Payload: Codable, Equatable, Sendable {
  public var connected: Bool?
  public var monitoring: Bool?
  public var mode: FocusMode?
  public var enabled: Bool?
  public var automaticFocus: Bool?
  public var webTabOpen: Bool?
  public var target: FocusTarget?
  public var success: Bool?
  public var error: String?
  public var openIfMissing: Bool?
  public var manual: Bool?
  public var preferredURL: String?
  public var origin: String?
  public var count: Int?
  public var lastEmail: String?
  public var lastCheck: String?
  public init() {}
}
public struct Envelope: Codable, Equatable, Sendable {
  public var v: Int
  public var type: MessageType
  public var id: String
  public var timestamp: String
  public var payload: Payload
  public init(_ type: MessageType, id: String = UUID().uuidString, payload: Payload = Payload()) {
    v = 1
    self.type = type
    self.id = id
    timestamp = InternetDate.string(Date())
    self.payload = payload
  }
  public func encoded() throws -> Data {
    let data = try JSONEncoder().encode(self)
    try Self.validate(data)
    return data
  }
  public static func decoded(_ data: Data) throws -> Envelope {
    try validate(data)
    return try JSONDecoder().decode(Envelope.self, from: data)
  }
  private static func validate(_ data: Data) throws {
    guard data.count <= 65536,
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(json.keys) == Set(["v", "type", "id", "timestamp", "payload"]),
      let version = json["v"] as? Int, version == 1, let typeString = json["type"] as? String,
      let type = MessageType(rawValue: typeString), let id = json["id"] as? String,
      UUID(uuidString: id) != nil, let time = json["timestamp"] as? String,
      InternetDate.parse(time) != nil, let payload = json["payload"] as? [String: Any]
    else { throw FocusFailure.invalid("Invalid native protocol envelope.") }
    let allowed: Set<String>
    switch type {
    case .hello: allowed = ["origin"]
    case .connectionStatus: allowed = ["connected", "webTabOpen", "error"]
    case .monitoringStatus: allowed = ["monitoring", "lastCheck", "lastEmail", "error"]
    case .mailNew: allowed = ["count", "lastEmail"]
    case .focusRequest: allowed = ["target", "openIfMissing", "preferredURL", "manual"]
    case .focusResult: allowed = ["success", "error", "target"]
    case .preferencesGet, .ping, .pong, .appSettings: allowed = []
    case .preferencesUpdate:
      allowed = ["mode", "enabled", "automaticFocus", "openIfMissing", "preferredURL"]
    }
    guard Set(payload.keys).isSubset(of: allowed) else {
      throw FocusFailure.invalid("Unsupported native payload fields.")
    }
    for (k, value) in payload {
      if let text = value as? String {
        guard text.count <= 500 else { throw FocusFailure.invalid("Native field too long.") }
        if k == "preferredURL" && !WebDestination.isAllowed(text) {
          throw FocusFailure.invalid("Unapproved Outlook Web destination.")
        }
        if k == "origin"
          && text.range(of: "^chrome-extension://[a-p]{32}/$", options: .regularExpression) == nil
        {
          throw FocusFailure.invalid("Invalid extension origin.")
        }
        if ["lastEmail", "lastCheck"].contains(k) && InternetDate.parse(text) == nil {
          throw FocusFailure.invalid("Invalid timestamp.")
        }
      }
    }
    let decoded = try JSONDecoder().decode(Envelope.self, from: data)
    if type == .hello && decoded.payload.origin == nil {
      throw FocusFailure.invalid("Missing host origin.")
    }
    if type == .focusRequest && decoded.payload.target == nil {
      throw FocusFailure.invalid("Missing focus target.")
    }
    if type == .focusResult && decoded.payload.success == nil {
      throw FocusFailure.invalid("Missing focus result.")
    }
    if let count = decoded.payload.count, !(0...100000).contains(count) {
      throw FocusFailure.invalid("Invalid message count.")
    }
  }
}
public struct EventCache: Sendable {
  private var ids: [String] = []
  private let capacity: Int
  public init(capacity: Int = 512) { self.capacity = capacity }
  public mutating func accept(_ id: String) -> Bool {
    if ids.contains(id) { return false }
    ids.append(id)
    if ids.count > capacity { ids.removeFirst(ids.count - capacity) }
    return true
  }
}
