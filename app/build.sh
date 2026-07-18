#!/bin/bash
# Build the pill and assemble Pill.app (no Xcode needed, CLT only).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="Pill.app"
BIN=".build/release/Pill"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Pill"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Pill</string>
  <key>CFBundleIdentifier</key><string>com.ccpill.pill</string>
  <key>CFBundleName</key><string>Pill</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>The pill listens so you can speak a prompt to a Claude session.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>The pill transcribes your voice into a prompt for Claude.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built: $(pwd)/$APP"

LABEL="com.ccpill.pill"
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/$LABEL"
  echo "agent restarted with new build"
fi
