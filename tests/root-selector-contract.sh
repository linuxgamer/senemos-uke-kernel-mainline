#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
flags=(-std=c++20 -O2 -Wall -Wextra -Werror -UNDEBUG)
if [[ ${SANITIZE:-0} == 1 ]]; then flags+=(-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer); fi
"${CXX:-c++}" "${flags[@]}" "$root/tests/root-selector-contract.cpp" -o "$work/test"
"$work/test"
cat > "$work/entry.c" <<'C'
#include <stddef.h>
#include <string.h>
#define UKE_INIT
#include "uke-root-selector.h"
int main(void) {
    char line[128] = "root=PARTLABEL=linux rw rootfstype=ext4,f2fs,xfs,btrfs panic=0";
    const char args[] = "senemos.root=userdata";
    return uke_select_root(line, sizeof(line), args, sizeof(args)) != 1 ||
        strcmp(line, "root=PARTLABEL=userdata rw rootfstype=ext4,f2fs,xfs,btrfs panic=10");
}
C
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -I"$root/src/boot" "$work/entry.c" -o "$work/c-test"
"$work/c-test"
echo 'Common Image root selection: default, exact overrides, duplicate/malformed refusal and bounded mutation passed'
