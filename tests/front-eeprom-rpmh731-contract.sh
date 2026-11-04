#!/usr/bin/env bash
# COPR only. Compare actual RPMh allowlist bodies; no regulator operations.
set -Eeuo pipefail
before=$(realpath "${1:?before camera source}")
after=$(realpath "${2:?after camera source}")
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
for variant in before after; do
 source=$before; [[ $variant != after ]] || source=$after
 awk '/if \(strcmp\(aggr_vreg->resource_name, "cx.lvl"/ {emit=1} emit {print} emit && /return -ENODEV;/ {exit}' \
  "$source" > "$work/$variant.h"
 test -s "$work/$variant.h"
done
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cerrno>
#include <cstring>
#include <initializer_list>
#include <cstdio>
using std::strcmp;
static int before(const char *name) {
 struct { const char *resource_name; } value{name}; auto *aggr_vreg = &value;
#include "before.h"
 return 0;
}
static int after(const char *name) {
 struct { const char *resource_name; } value{name}; auto *aggr_vreg = &value;
#include "after.h"
 return 0;
}
int main() {
 for (auto name : {"cx.lvl","mx.lvl","lcx.lvl","lmx.lvl","mxc.lvl",
  "ldob2","ldob3","ldob4","ldob7","ldob17","smpb2","smpb1","smpb3",
  "ldod1","ldob5","ldob12","ldod3","mmcx.lvl","smpe3","ldob8",
  "nsp.lvl","ldoe7","bobb1"}) assert(!before(name) && !after(name));
 assert(before("ldob20") == -ENODEV && !after("ldob20"));
 for (auto name : {"","ldob","ldob1","ldob19","ldob21","ldob30",
  "ldob020","ldob20 ","LDOB20","ldoc20","ldoe20","bobb2","foreign"})
  assert(before(name) == -ENODEV && after(name) == -ENODEV);
 puts("Actual RPMh: exactly ldob20 added, existing resources retained and neighboring/foreign names refused; no voltage or hardware operation");
}
CPP
read -ra flags <<< "${FRONT_EEPROM_TEST_FLAGS:-}"
"${CXX:-clang++}" -std=c++20 -Wall -Wextra -Werror -O1 -g "${flags[@]}" \
 -I"$work" "$work/check.cpp" -o "$work/check"
"$work/check"
