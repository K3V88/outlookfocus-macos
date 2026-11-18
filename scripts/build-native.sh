#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swift scripts/create-icons.swift
swift build -c release --product MailFocus
swift build -c release --product MailFocusNativeHost
MAILFOCUS_BIN="$(swift build -c release --show-bin-path)"
MAILFOCUS_APP="$PWD/build/MailFocus.app"
mkdir -p "$MAILFOCUS_APP/Contents/MacOS" "$MAILFOCUS_APP/Contents/Resources"
cp "$MAILFOCUS_BIN/MailFocus" "$MAILFOCUS_APP/Contents/MacOS/MailFocus"
cp "$MAILFOCUS_BIN/MailFocusNativeHost" "$MAILFOCUS_APP/Contents/MacOS/MailFocusNativeHost"
cp macos/MailFocus/Info.plist "$MAILFOCUS_APP/Contents/Info.plist"
iconutil -c icns build/MailFocus.iconset -o "$MAILFOCUS_APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$MAILFOCUS_APP/Contents/MacOS/MailFocusNativeHost"
codesign --force --sign - "$MAILFOCUS_APP"
codesign --verify --deep --strict "$MAILFOCUS_APP"
plutil -lint "$MAILFOCUS_APP/Contents/Info.plist"
printf 'Built and locally ad-hoc signed: %s\n' "$MAILFOCUS_APP"
