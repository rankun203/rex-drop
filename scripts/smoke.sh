#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
"$project_dir/scripts/build.sh"
REX_DROP_INTEGRATION=1 exec "$project_dir/scripts/test.sh" --filter RexIntegrationTests "$@"
