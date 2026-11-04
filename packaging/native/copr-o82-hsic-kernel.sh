#!/usr/bin/env bash
# Active development uses the unstable family. Normal7500 is historical at8dd80a9.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
exec bash "$root/packaging/native/copr-o82-hsic-unstable.sh" "$@"
