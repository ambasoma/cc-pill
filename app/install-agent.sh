#!/bin/bash
# Install the pill as a launchd LaunchAgent: starts at login, auto-restarts
# if it crashes or is killed. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"

LABEL="com.ccpill.pill"
BIN="$(pwd)/Pill.app/Contents/MacOS/Pill"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

[ -x "$BIN" ] || { echo "Build first: ./build.sh"; exit 1; }

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x Pill 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart "gui/$(id -u)/$LABEL"
echo "installed: $LABEL (starts at login, auto-restarts on death)"
