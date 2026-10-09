#!/bin/zsh
# ./build.sh       build, install to ~/Applications and relaunch
# ./build.sh dmg   build Tokenbar.dmg to share with another Mac
set -e
cd "${0:A:h}"
VERSION=1.3
APP=build/Tokenbar.app

if [[ ! -f icon/AppIcon.icns ]]; then
  swiftc icon/make-icon.swift -o /tmp/make-icon && /tmp/make-icon /tmp/tokenbar-icon.png
  mkdir -p /tmp/AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s /tmp/tokenbar-icon.png --out /tmp/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) /tmp/tokenbar-icon.png --out /tmp/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns /tmp/AppIcon.iconset -o icon/AppIcon.icns && rm -rf /tmp/AppIcon.iconset
fi

rm -rf build && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
# Universal binary: Apple Silicon + Intel.
for arch in arm64 x86_64; do
  swiftc -O -target $arch-apple-macos13 main.swift -o build/Tokenbar-$arch
done
lipo -create build/Tokenbar-* -output $APP/Contents/MacOS/Tokenbar && rm build/Tokenbar-*
cp icon/AppIcon.icns $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Tokenbar</string>
  <key>CFBundleIdentifier</key><string>com.hritik.tokenbar</string>
  <key>CFBundleExecutable</key><string>Tokenbar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSUserNotificationAlertStyle</key><string>alert</string>
</dict></plist>
PLIST
codesign --force --sign - $APP  # ad-hoc: no Apple Developer ID, so Gatekeeper asks once on other Macs

if [[ $1 == dmg ]]; then
  rm -rf build/dmg && mkdir build/dmg && cp -R $APP build/dmg/ && ln -s /Applications build/dmg/Applications
  hdiutil create -volname Tokenbar -srcfolder build/dmg -ov -format UDZO Tokenbar.dmg >/dev/null
  echo "Built Tokenbar.dmg"
  exit
fi

# Remove the app's pre-rename install (Claude Usage → Tokenbar).
pkill -x ClaudeUsageBar || true
rm -rf ~/Applications/ClaudeUsageBar.app

pkill -x Tokenbar || true
rm -rf ~/Applications/Tokenbar.app && cp -R $APP ~/Applications/
open ~/Applications/Tokenbar.app
