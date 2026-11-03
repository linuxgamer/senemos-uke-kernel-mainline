#!/usr/bin/env bash
# Host-only actual allowlist boundary; does not emulate voltage programming.
set -Eeuo pipefail
source_file=${1:?Pass prepared drivers/regulator/qcom-rpmh-regulator-uke.c}
stage=${2:-native}
case $stage in pre-native|before-nfc|before-audio|native) ;; *) exit 64;; esac
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
{
    cat <<'CPP'
#include <cassert>
#include <cerrno>
#include <cstring>
#include <initializer_list>
using std::strcmp;
int admission(const char *name) {
    struct { const char *resource_name; } storage{name};
    auto *aggr_vreg=&storage;
CPP
    awk '/if \(strcmp\(aggr_vreg->resource_name, "cx.lvl"/ {emit=1} emit {print} emit && /return -ENODEV;/ {exit}' "$source_file"
    cat <<'CPP'
    return 0;
}
int main(int argc,char **argv) {
    assert(argc==2);
    const bool native=strcmp(argv[1],"pre-native");
    for(auto name : {"cx.lvl","mx.lvl","lcx.lvl","lmx.lvl","mxc.lvl",
                     "ldob2","ldob3","ldob4","ldob7","ldob17","smpb2","smpb1",
                     "smpb3","ldod1","ldob5","ldob12","ldod3"})
        assert(admission(name)==0);
    for(auto name : {"mmcx.lvl","smpe3","ldob8","nsp.lvl"})
        assert(admission(name)==(native?0:-ENODEV));
    const bool nfc=!strcmp(argv[1],"before-audio") || !strcmp(argv[1],"native");
    assert(admission("ldoe7")== (nfc?0:-ENODEV));
    assert(admission("bobb1")==(!strcmp(argv[1],"native")?0:-ENODEV));
    for(auto name : {"","ldob","ldob1","ldob30","ldob3 ","LDOB3","ldoc2",
                     "lcx","nsp","nsp.lvl ","NSP.LVL","nsp.lvlx","ldob19","ldoc3","ldoe6","ldoe8","LDOE7","ldoe7 ",
                     "bob","bobb","bobb0","bobb2","bobb1 ","BOBB1","anything"}) assert(admission(name)==-ENODEV);
}
CPP
} > "$work/check.cpp"
"${CXX:-clang++}" -std=c++20 -O2 -Wall -Wextra -Werror "$work/check.cpp" -o "$work/check"
"$work/check" "$stage"
printf 'Actual Uke RPMh admission retains bounded %s resource scope, including the exact BOB gate: passed\n' "$stage"
