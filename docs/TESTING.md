# Validation and manual end-to-end testing

## Verified results

Checked locally on 18 November 2026: **41 native XCTest cases, 25 Vitest cases, 5 Chromium native-host integration tests, and the separate framing/IPC process test pass**. The Xcode project’s XCTest scheme passes; release app/host builds, local ad-hoc signature verification, Swift-format lint, TypeScript checks, and the Chrome production package verification pass. The runtime dependency audit reports zero vulnerabilities; the full dev tree reports five entries tracing to the documented picomatch advisory.

The local read-only environment diagnostic found Outlook installed but not running, and Chrome installed/running. No actual foreground switch, Microsoft sign-in, notification authorization, login-item change, or real email delivery was performed.

## Automated coverage

Native XCTest covers PKCE, least-privilege authorization parameters, state rejection before network access, refresh caching/coalescing, HTTP 401 retry, persistent throttling, baseline suppression, genuine new-ID/arrival detection, duplicates and ordinary modifications, removal/old moves, paginated checkpointing, large bounded rounds, cursor expiry, restarts, account changes, cancellation/reset races, non-overlap, quiet hours, cooldown, Smart fallback, preferences, origin/URL validation, framing and active-socket ownership.

Vitest covers verified tab discovery, preference ranking, tab/window activation, missing tabs, no-window/error handling, no duplicate tab creation, event coalescing, strict protocol parsing, invalid/credential payload rejection, bounded alarm delays, stale native-port replacement and reconnect limits.

Five Chromium tests exercise the production extension, the **compiled production native host**, framing, local IPC, actual toolbar popup, request/result correlation, existing tab activation, explicit versus unauthorized new-tab opening, and reconnection after the app-side bridge restarts. A clearly named test-only app-side fixture supplies generic events; it is not fake Microsoft authentication. Test pages are fixtures, external DNS is blocked, and no real mailbox or normal browser profile is used.

The Xcode project and command-line packaged `.app` are both build targets. Local signatures are ad-hoc, not notarized. Inspect the latest command output and CI run rather than inferring live account readiness from a build pass.

## Reproduce locally

```sh
npm ci --prefix chrome-extension
cd chrome-extension && npx playwright install chromium && cd ..
./scripts/test-all.sh
xcodebuild -project macos/OutlookFocus.xcodeproj -scheme OutlookFocus \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/Xcode CODE_SIGNING_ALLOWED=NO test
```

`swift test` builds the debug host/fixture required by process and browser integration. Test directories are created under `/private/tmp` to stay within Unix socket path limits and are removed afterward. Your default Chrome profile and host registrations are not modified by these tests.

## Manual Desktop end-to-end check

1. Build/install the packaged app and complete Entra sign-in in Settings → Monitoring.
2. Leave monitoring off initially. Check the connected account is the one you intend to monitor.
3. Choose Desktop mode. Enable **Open Outlook when closed** if needed. Click **Test Desktop Activation**. Verify Outlook actually becomes frontmost; note any OS restriction/error.
4. Enable monitoring and wait for **Inbox baseline established** / a last successful check. Existing messages must not cause focus.
5. Work in another app. Send one genuinely new email to the connected Microsoft Inbox from another account.
6. Wait at least the configured interval plus service latency. Verify Outlook comes forward once and the last-email timestamp updates.
7. Mark that same message read/unread or edit it. Verify this does not trigger another activation.
8. Test high-importance filtering, quiet hours, cooldown, paused monitoring, Notification Only and Disabled modes.
9. Quit/relaunch the app. Old mail should not replay. Test sleep/wake and temporarily disconnected networking.

This check requires your Microsoft account/registration and may be affected by organizational policy. It has **not** been run with a real account during implementation.

## Manual Chrome end-to-end check

1. Build/load `chrome-extension/dist` through chrome://extensions with Developer mode enabled.
2. Register the native host using that extension card's actual ID and the stable installed app path.
3. Keep the Mac app running. Click Retry Connection; expect Connected to Mac Helper.
4. Open the intended Outlook Web account on a supported host. Choose Chrome mode and the corresponding preferred web host in the Mac settings.
5. Click **Test Chrome Activation**, then work in a different app and send a new email after the baseline has finished.
6. Verify the right existing Outlook tab and Chrome window come forward, without a duplicate tab. Chrome's browser activation and the Mac application's actual foreground state must both be checked manually.
7. Close all Outlook tabs. With automatic opening disabled, new mail should report unavailable focus without opening a tab. Enable opening, retry with a new mail or explicit Open Outlook Web, and verify only one tab is created.
8. Test Smart Mode with Outlook running and then closed. Verify Desktop preference, existing web-tab preference, and configured fallback.
9. Quit/restart Chrome and the Mac app separately. Connection loss must be visible. Retry should restore connection; stale automatic focus must not replay.
10. Disconnect the Microsoft account. Monitoring should stop, timestamps reset, Keychain app cache and committed/pending sync files should be removed. Revoke Microsoft consent separately if desired.

## Permissions and setup checks not performed automatically

Real Microsoft OAuth/consent, Keychain access with a real token, actual email delivery, Desktop foreground switching, optional notification consent, Login Items approval, and installation into your normal browser profile require user setup or interaction. No successful live-account result, notarization, App Store or Chrome Web Store publication is claimed.

## Dependency audit

The extension has no npm runtime dependencies. The full dev tree reports cascading high-severity entries for the upstream [picomatch ReDoS advisory](https://github.com/advisories/GHSA-fc5q-39xc-vjpf) in build/test tooling. The latest available picomatch during validation was still affected. Production code is not bundled with that package; test/build glob patterns are repository-controlled. Do not use `npm audit fix --force` to silently downgrade the tested toolchain. Adopt a patched upstream version when available.
