# Native protocol v1

The macOS app and native host are separate processes. Chrome starts the host only after the extension opens `runtime.connectNative("com.k3v88.mailfocus.host")`. That persistent port keeps the MV3 worker alive while connected. On disconnect the extension uses alarms at 30s, 60s, 120s, 240s and then up to 300s, stopping after eight scheduled automatic retries. Retry counters, stop state and next-attempt deadlines survive worker suspension in session storage. Waking the worker early does not bypass the saved backoff. Retry Connection resets the attempt counter. No polling of Microsoft Graph occurs in Chrome.

## Framing and validation

Both stdio and Unix socket transports use a **four-byte unsigned length prefix in native byte order**, followed by exactly that many UTF-8 JSON bytes. Supported macOS ARM64/x86_64 systems are little endian. This implementation limits each JSON message to **64 KiB**, below Chrome's 1 MiB native-to-extension limit. Partial reads/writes and EINTR are handled. Invalid/truncated/oversized data closes the channel; stdout is reserved for framed protocol data.

Every envelope has exactly these keys:

```json
{
  "v": 1,
  "type": "ping",
  "id": "57d6f234-a629-4fd5-8382-93a8404e81c4",
  "timestamp": "2026-11-18T10:00:00Z",
  "payload": {}
}
```

The example UUID is a protocol example, not an extension identity. `id` is a UUID correlation/event ID; timestamps are ISO 8601. Unknown versions, message types, envelope keys or type-specific payload keys are rejected. Boolean, enum, timestamp, length/count and destination values are validated independently in Swift and TypeScript.

| Message | Allowed payload |
| --- | --- |
| hello | origin (required, host-controlled) |
| connection.status | connected, webTabOpen, error |
| monitoring.status | monitoring, lastCheck, lastEmail, error |
| mail.new | count, lastEmail |
| focus.request | target (desktop/chrome, required), openIfMissing, preferredURL, manual |
| focus.result | success (required), target, error |
| preferences.get | empty |
| preferences.update | mode, enabled, automaticFocus, openIfMissing, preferredURL |
| app.settings | empty |
| ping / pong | empty |

No token, authorization code, message body, subject, account address, filesystem path or shell-command field exists in the protocol. Errors are generic/sanitized. preferredURL is limited to HTTPS on the four explicit Outlook hosts, without userinfo or a nonstandard port.

## Lifecycle

1. Chrome verifies its manifest's allowed origin and starts the registered absolute executable.
2. The host verifies Chrome's supplied origin against the private per-user origin file; it never accepts an extension-provided `hello` frame.
3. It connects to the app's private Unix socket and validates the peer UID. The server validates the host-side UID and hello origin too.
4. The app sends connection and preference/monitoring snapshots. Chrome reports only whether a supported Outlook tab exists.
5. A committed new-mail batch updates generic status. The app's focus policy chooses a destination. `mail.new` alone never triggers Chrome focus.
6. For Chrome, the app sends a unique `focus.request`. The extension validates mode, serializes tab operations, reuses existing tabs, and returns `focus.result` with the **same ID**.
7. The app waits at most 10 seconds for the Chrome acknowledgement, then requests macOS foreground activation. Waiting for a newly launched Chrome bridge also has a 10-second limit. Manual extension-to-app focus requests have a 25-second deadline and receive a result too.

Duplicate inbound events are suppressed. Chrome retains up to 128 focus results in session storage across MV3 worker restarts; in-flight requests are coalesced by ID. The app retains a bounded inbound event cache and durable mailbox IDs/cursors. Outbound automatic focus commands are not buffered for later delivery after an outage: replaying stale focus would be disruptive.

## Installation and tests

The installer accepts the **actual** Chrome extension ID, verifies the executable, and generates the manifest and private origin list. No fixed development identity is guessed. Tests obtain the real ID through Chrome DevTools and register only inside a temporary browser user-data directory.

`MAILFOCUS_TEST_SUPPORT_DIR` is an explicit test-process environment override for the host's local support directory. It cannot be set through a native message. Production app storage uses the normal user Application Support directory. The test-only BridgeFixture executable accepts its temporary directory as an argument and never authenticates, polls Graph, launches applications or ships in the `.app` bundle.

Reference: [Chrome native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging).
