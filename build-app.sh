#!/bin/zsh
# Builds OnAir for Mac.app (ad-hoc signed) and the ngmic CLI into ./dist
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product OnAir
swift build -c release --product ngmic
BIN=$(swift build -c release --show-bin-path)

APP="dist/OnAir for Mac.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
[ -f Resources/AppIcon.icns ] || { swift Tools/make-icon.swift && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns; }
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/OnAir" "$APP/Contents/MacOS/OnAir"
cp "$BIN/ngmic" dist/ngmic

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>OnAir for Mac</string>
  <key>CFBundleDisplayName</key><string>OnAir for Mac</string>
  <key>CFBundleIdentifier</key><string>local.onair-mac</string>
  <key>CFBundleExecutable</key><string>OnAir</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Shows your microphone's live input level in the mixer.</string>
</dict>
</plist>
PLIST

# Hardened runtime: no DYLD_* injection into a process that holds the Microphone grant.
codesign --force --sign - --options runtime --entitlements Resources/OnAir.entitlements "$APP"
codesign --force --sign - --options runtime dist/ngmic
echo "Built: $APP and dist/ngmic"
