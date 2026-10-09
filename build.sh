#!/bin/zsh
# Builds ClaudeUsageBar.app into ~/Applications and restarts it.
set -e
cd "${0:A:h}"
APP=~/Applications/ClaudeUsageBar.app
if [[ ! -f AppIcon.icns ]]; then
  swiftc make-icon.swift -o /tmp/make-icon && /tmp/make-icon icon.png
  mkdir -p AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s icon.png --out AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) icon.png --out AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns AppIcon.iconset && rm -rf AppIcon.iconset
fi
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
swiftc -O main.swift -o $APP/Contents/MacOS/ClaudeUsageBar
cp AppIcon.icns $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Claude Usage</string>
  <key>CFBundleIdentifier</key><string>com.hritik.claude-usage-bar</string>
  <key>CFBundleExecutable</key><string>ClaudeUsageBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>NSUserNotificationAlertStyle</key><string>alert</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign - $APP
# Start at login via LaunchAgent; KeepAlive restarts on crash but not on Quit.
AGENT=~/Library/LaunchAgents/com.hritik.claude-usage-bar.plist
if [[ ! -f $AGENT ]]; then
  cat > $AGENT <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.hritik.claude-usage-bar</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/ClaudeUsageBar</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict></plist>
PLIST
  launchctl bootstrap gui/$(id -u) $AGENT
else
  pkill -x ClaudeUsageBar || true  # launchd restarts it from the new bundle
fi
