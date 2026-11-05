#!/bin/sh
# Compatibility entry point; maintained scripts live in scripts/.
set -eu
exec "$(dirname -- "$0")/scripts/test.sh" "$@"
