#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swift scripts/create-icons.swift
swift build -c release --product OutlookFocus
swift build -c release --product OutlookFocusNativeHost
OUTLOOKFOCUS_BIN="$(swift build -c release --show-bin-path)"
OUTLOOKFOCUS_APP="$PWD/build/OutlookFocus.app"
mkdir -p "$OUTLOOKFOCUS_APP/Contents/MacOS" "$OUTLOOKFOCUS_APP/Contents/Resources"
cp "$OUTLOOKFOCUS_BIN/OutlookFocus" "$OUTLOOKFOCUS_APP/Contents/MacOS/OutlookFocus"
cp "$OUTLOOKFOCUS_BIN/OutlookFocusNativeHost" "$OUTLOOKFOCUS_APP/Contents/MacOS/OutlookFocusNativeHost"
cp macos/OutlookFocus/Info.plist "$OUTLOOKFOCUS_APP/Contents/Info.plist"
iconutil -c icns build/OutlookFocus.iconset -o "$OUTLOOKFOCUS_APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$OUTLOOKFOCUS_APP/Contents/MacOS/OutlookFocusNativeHost"
codesign --force --sign - "$OUTLOOKFOCUS_APP"
codesign --verify --deep --strict "$OUTLOOKFOCUS_APP"
plutil -lint "$OUTLOOKFOCUS_APP/Contents/Info.plist"
printf 'Built and locally ad-hoc signed: %s\n' "$OUTLOOKFOCUS_APP"
