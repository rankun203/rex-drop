#!/bin/sh
set -eu
exec "$(dirname -- "$0")/test.sh" --filter ClipboardTests "$@"
