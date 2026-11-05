#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p .build/module-cache
xcrun swiftc -parse-as-library -module-cache-path .build/module-cache Clipboard.swift ClipboardTests.swift -o .build/clipboard-tests
exec .build/clipboard-tests
