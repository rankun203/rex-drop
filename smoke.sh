#!/bin/sh
set -eu
package_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$package_dir/.build"
/usr/bin/xcrun swiftc -module-cache-path "$package_dir/.build/module-cache" \
  -parse-as-library "$package_dir/Backend.swift" "$package_dir/SmokeTests.swift" -o "$package_dir/.build/smoke-tests"
exec "$package_dir/.build/smoke-tests" "$package_dir/.build/Rex Drop.app/Contents/MacOS/RexDrop"
