#!/bin/bash
# Build, self-check, install and (re)start EyeBreak. Safe to re-run any time.
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/EyeBreak.app"
PLIST="$HOME/Library/LaunchAgents/com.user.eyebreak.plist"
GUI="gui/$(id -u)"

launchctl bootout "$GUI/com.user.eyebreak" 2>/dev/null || true   # stop the old copy first
pkill -x EyeBreak 2>/dev/null || true

mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>EyeBreak</string>
  <key>CFBundleIdentifier</key><string>com.user.eyebreak</string>
  <key>CFBundleName</key><string>EyeBreak</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
EOF

# no -O: asserts in selfCheck must survive, and this app uses no measurable CPU
swiftc -o "$APP/Contents/MacOS/EyeBreak" "$SRC/main.swift"
"$APP/Contents/MacOS/EyeBreak" --selfcheck     # set -e aborts the install if this fails

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.user.eyebreak</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/EyeBreak</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardErrorPath</key><string>/tmp/com.user.eyebreak.err</string>
</dict></plist>
EOF
plutil -lint "$PLIST"

launchctl enable "$GUI/com.user.eyebreak" 2>/dev/null || true
launchctl bootstrap "$GUI" "$PLIST"
sleep 1
launchctl print "$GUI/com.user.eyebreak" | grep -E "^\s+(state|pid) "
echo "OK — メニューバーに目のアイコンが出ていれば完了です"
