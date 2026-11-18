import Darwin
import Foundation
import MailFocusCore

// Explicit test-only executable. No Graph, authentication, or application activation.
guard CommandLine.arguments.count == 2 else {
  fputs("Usage: BridgeFixture <private-test-directory>\n", stderr)
  exit(2)
}
let paths = AppPaths(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
let bridge = BridgeServer(paths: paths)
bridge.onMessage = { id, message in
  do {
    switch message.type {
    case .hello:
      var p = Payload()
      p.connected = true
      try bridge.send(Envelope(.connectionStatus, payload: p), to: id)
    case .ping: try bridge.send(Envelope(.pong, id: message.id), to: id)
    case .preferencesGet:
      var p = Payload()
      p.mode = .chrome
      p.enabled = true
      p.automaticFocus = true
      p.openIfMissing = false
      p.preferredURL = "https://outlook.office.com/mail/"
      try bridge.send(Envelope(.preferencesUpdate, payload: p), to: id)
    case .focusRequest:
      var p = Payload()
      p.target = .chrome
      p.manual = true
      p.openIfMissing = message.payload.openIfMissing ?? false
      p.preferredURL = "https://outlook.office.com/mail/"
      try bridge.send(Envelope(.focusRequest, id: message.id, payload: p), to: id)
    case .focusResult: try bridge.send(message, to: id)
    default: break
    }
  } catch {}
}
do {
  try bridge.start()
  fputs("BRIDGE_READY\n", stderr)
  dispatchMain()
} catch {
  fputs("Could not start test bridge.\n", stderr)
  exit(1)
}
