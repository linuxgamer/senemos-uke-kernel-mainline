#!/usr/bin/env bash
# Host-only libfdt fixture and optional retained-FDT transformation.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
${CXX:-c++} ${CPPFLAGS:-} -std=c++17 -O2 -Wall -Wextra -Werror "$root/tests/hardware-dt.cpp" ${LIBFDT_LIBS:--lfdt} -o "$work/test"
"$work/test" "$@"
