# Generated native manifest

Run `python3 native-messaging/install/install-host.py --extension-id YOUR_ACTUAL_ID` after loading the extension. The installer creates a valid JSON manifest with an absolute executable path and the actual verified extension origin. No guessed fixed extension ID is embedded in this project. Reloading the same unpacked directory preserves its ID; moving it can change the ID and requires re-registration.

Use `--app "$HOME/Applications/MailFocus.app"` if you copy the app to your user Applications directory. `--browser chrome-testing` or `--browser chromium` selects those browser-specific user-level registration directories. No administrator permissions are required.
