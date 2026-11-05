#!/bin/sh
set -eu
package_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app="$package_dir/.build/Rex Drop.app"
if [ ! -x "$app/Contents/MacOS/RexDrop" ]; then
  printf 'Build first: "%s/build.sh"\n' "$package_dir" >&2
  exit 1
fi
# LaunchServices gives replacement logic the desktop's running-app inventory.
exec /usr/bin/open -n "$app" --args --replace-running
