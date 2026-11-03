#!/usr/bin/env bash
# Host-only actual admission helper; no MMIO, keys or storage writes.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
${CXX:-c++} ${CPPFLAGS:-} -std=c++17 -O2 -Wall -Wextra -Werror "$root/tests/ufs-ice-contract.cpp" ${LIBFDT_LIBS:--lfdt} -o "$work/test"
"$work/test" "$@"
