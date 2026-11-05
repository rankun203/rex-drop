#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p .build/module-cache
xcrun swiftc -parse-as-library -module-cache-path .build/module-cache Backend.swift BackendTests.swift -o .build/backend-tests
exec .build/backend-tests
