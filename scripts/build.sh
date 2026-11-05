#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
swift build --package-path "$project_dir" --configuration release --product RexDrop
bin_dir=$(swift build --package-path "$project_dir" --configuration release --show-bin-path)
app="$project_dir/.build/Rex Drop.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/RexDrop" "$app/Contents/MacOS/RexDrop"
cp "$project_dir/Resources/Info.plist" "$app/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app"
printf '\nBuilt: %s\nLaunch: "%s/scripts/launch.sh"\n' "$app" "$project_dir"
