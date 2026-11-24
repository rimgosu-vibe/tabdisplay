#!/bin/zsh
# Builds TabDisplay.app
set -e
cd "${0:A:h}"
APP=build/TabDisplay.app  # relative to mac/
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -import-objc-header Sources/CGVirtualDisplay.h Sources/main.swift \
  -o "$APP/Contents/MacOS/tabdisplay"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>kr.rimgosu.tabdisplay</string>
  <key>CFBundleName</key><string>TabDisplay</string>
  <key>CFBundleExecutable</key><string>tabdisplay</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION:-0.0.0}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
# Ad-hoc sign, but pin the designated requirement to the bundle id so the
# Screen Recording (TCC) grant survives rebuilds (default DR would be the cdhash).
codesign --force --sign - --identifier kr.rimgosu.tabdisplay \
  -r='designated => identifier "kr.rimgosu.tabdisplay"' "$APP"
echo "built $APP"
