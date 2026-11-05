#!/bin/sh
set -eu
package_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
app="$package_dir/.build/Rex Drop.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
/usr/bin/xcrun swiftc -module-cache-path "$package_dir/.build/module-cache" \
  -O "$package_dir/Backend.swift" "$package_dir/Lifecycle.swift" "$package_dir/RexDrop.swift" -o "$app/Contents/MacOS/RexDrop"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Rex Drop</string>
  <key>CFBundleDisplayName</key><string>Rex Drop</string>
  <key>CFBundleIdentifier</key><string>io.github.rankun203.rexdrop</string>
  <key>CFBundleExecutable</key><string>RexDrop</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.5.0</string>
  <key>CFBundleVersion</key><string>5</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$app"
printf '\nBuilt: %s\nLaunch: "%s/launch.sh"\n' "$app" "$package_dir"
