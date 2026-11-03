#!/usr/bin/env bash
# Host-only ACDB graph metadata; synthetic data, no OEM or device access.
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
${CXX:-c++} -std=c++20 -Wall -Wextra -Werror -fsanitize=address,undefined \
    "$root/src/audio/acdb-graph-audit.cpp" -o "$work/audit"
"$work/audit" --self-test
