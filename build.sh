#!/bin/bash
# Build, self-check, install and (re)start EyeBreak. Safe to re-run any time:
# the build and self-check run in a temp dir first, so a failure leaves the
# installed app and its LaunchAgent completely untouched (and still running).
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/EyeBreak.app"
PLIST="$HOME/Library/LaunchAgents/com.user.eyebreak.plist"
GUI="gui/$(id -u)"

# no -O: asserts in selfCheck must survive (it verifies this itself), and the
# app uses no measurable CPU anyway
TMP="$(mktemp -d)"
swiftc -o "$TMP/EyeBreak" "$SRC/main.swift"
"$TMP/EyeBreak" --selfcheck            # set -e: nothing below runs if this fails

# Only now touch the installed copy. Boot out the old agent BEFORE replacing
# its binary: overwriting a running executable gets it SIGKILLed by
# code-signature verification and KeepAlive resurrects it in a crash loop.
launchctl bootout "$GUI/com.user.eyebreak" 2>/dev/null || true
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
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
EOF
mv -f "$TMP/EyeBreak" "$APP/Contents/MacOS/EyeBreak"

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
# Retry once: bootout can still be draining the old job for a moment.
launchctl bootstrap "$GUI" "$PLIST" || { sleep 2; launchctl bootstrap "$GUI" "$PLIST"; }
sleep 1
launchctl print "$GUI/com.user.eyebreak" | grep -E "^\s+(state|pid) "
echo "OK — Dock に目のアイコンが出ていれば完了です"
