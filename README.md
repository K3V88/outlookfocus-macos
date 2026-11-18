# MailFocus — Apple Mail + Infomaniak

The macOS menu-bar app now monitors an Infomaniak Inbox configured in Apple Mail and brings Apple Mail forward when a new message arrives. The app is named MailFocus. Existing local settings are imported automatically on the first launch after the rename.

## Setup

1. Configure your Infomaniak email in Apple Mail using [Infomaniak’s setup tool](https://config.infomaniak.com).
2. Open `build/MailFocus.app`. Settings opens on **Monitoring**. Clicking the envelope beside the clock opens Settings directly; right-click it for quick actions.
3. Enter the email address configured in Apple Mail and click **Connect Apple Mail**.
4. Allow MailFocus to control Mail when macOS prompts. If denied, enable it in **System Settings → Privacy & Security → Automation**.
5. In **General**, enable Inbox monitoring and automatic focus. Allow opening Apple Mail when closed if desired.
6. Keep Mail synchronized: **Mail → Settings → General → Check for new messages → Automatically**.
7. Test **Diagnostics → Test Apple Mail Activation**, then send a new message from another account. Detection follows Mail’s own synchronization plus the polling interval (30 seconds by default).

Microsoft Entra setup and Microsoft sign-in are no longer part of the macOS app. Apple Mail manages the Infomaniak password; MailFocus does not request or store it. Monitoring reads local message IDs and received dates through Mail’s scripting interface, without reading subjects or bodies. It does not send, move, mark, or delete messages.

## Behavior

The first successful check establishes a baseline. Existing messages do not activate Mail. Account changes, reset, wake, restart, and re-enabling monitoring establish a fresh baseline; messages received while monitoring was stopped are not replayed. Read/unread changes, duplicate IDs, and old messages moved into Inbox do not activate Mail. Quiet hours, optional cooldown, manual activation, and optional Launch at Login remain available. The default cooldown is zero so each new delivery can activate Mail; manual tests never start the automatic cooldown.

One email address is monitored at a time. The account must be enabled in Apple Mail and expose its IMAP `INBOX` mailbox, as Infomaniak accounts do. The app observes Mail’s local synchronization; it does not contact Infomaniak’s servers directly. Incoming-mail behavior still requires a real-account test after granting Automation permission.

## Build and test

Requires macOS 14+ and Xcode with Swift 5.9+.

```sh
./scripts/build-native.sh
swift test
```

The packaging script locally signs `build/MailFocus.app` and retains the legacy native host in the bundle. The current macOS app does not start that bridge or activate Chrome. Legacy Graph and Chrome code remain in the repository; [previous documentation](docs/OUTLOOK-LEGACY.md) describes those components.

Tests cover baseline establishment, fresh arrivals, deduplication, moved old mail, account changes, and reset, along with the existing core tests.

Email addresses are saved immediately to a private `mail-account.json` file in `~/Library/Application Support/MailFocus/` and restored across launches. Invalid or empty editing drafts do not erase the saved account. Monitoring shows “Email saved on this Mac” after a successful write. Mailbox-check failures remain visible even after a successful manual activation test.
