#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# Some Command Line Tools builds omit the bundled Testing macro search path.
# Resolve it from the selected toolchain rather than a machine-specific path.
compiler_dir=$(dirname -- "$(xcrun --find swiftc)")
testing_plugins="$compiler_dir/../lib/swift/host/plugins/testing"
if [ -d "$testing_plugins" ]; then
  set -- -Xswiftc -plugin-path -Xswiftc "$testing_plugins" "$@"
fi
exec swift test --package-path "$project_dir" --disable-xctest "$@"
