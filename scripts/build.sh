#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/KubeBar.app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -module-cache-path "$PWD/build/ModuleCache" -swift-version 5 -O -framework AppKit Sources/main.swift -o "$APP/Contents/MacOS/KubeBar"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>KubeBar</string>
<key>CFBundleIdentifier</key><string>local.kubebar.app</string>
<key>CFBundleName</key><string>KubeBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
