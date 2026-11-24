#!/bin/zsh
# Builds mac/build/TabDisplay.app
#   - bundles adb (Google platform-tools) as Contents/MacOS/adb
#   - bundles the Android APK as Contents/Resources/TabDisplay.apk if APK_PATH is set
#   VERSION=x.y.z  APK_PATH=path/to.apk  mac/build.sh
set -e
cd "${0:A:h}"
APP=build/TabDisplay.app
CACHE=build/cache
mkdir -p "$CACHE"

# adb
if [ ! -x "$CACHE/platform-tools/adb" ]; then
  echo "downloading platform-tools…"
  curl -fsSL -o "$CACHE/platform-tools.zip" https://dl.google.com/android/repository/platform-tools-latest-darwin.zip
  rm -rf "$CACHE/platform-tools"
  unzip -q "$CACHE/platform-tools.zip" 'platform-tools/adb' 'platform-tools/NOTICE.txt' -d "$CACHE"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -import-objc-header Sources/CGVirtualDisplay.h Sources/*.swift \
  -o "$APP/Contents/MacOS/tabdisplay"
cp "$CACHE/platform-tools/adb" "$APP/Contents/MacOS/adb"
cp "$CACHE/platform-tools/NOTICE.txt" "$APP/Contents/Resources/adb-NOTICE.txt"
if [ -n "$APK_PATH" ]; then cp "$APK_PATH" "$APP/Contents/Resources/TabDisplay.apk"; fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>kr.rimgosu.tabdisplay</string>
  <key>CFBundleName</key><string>TabDisplay</string>
  <key>CFBundleDisplayName</key><string>TabDisplay</string>
  <key>CFBundleExecutable</key><string>tabdisplay</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION:-0.0.0}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>github.com/rimgosu-vibe/tabdisplay</string>
</dict></plist>
PLIST

# Ad-hoc sign, but pin the designated requirement to the bundle id so the
# Screen Recording / Accessibility (TCC) grants survive rebuilds and updates.
# (adb keeps Google's own signature as nested code.)
codesign --force --sign - --identifier kr.rimgosu.tabdisplay \
  -r='designated => identifier "kr.rimgosu.tabdisplay"' "$APP"
echo "built $APP"
