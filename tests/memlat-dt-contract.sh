#!/usr/bin/env bash
# COPR host only: native path admission, retained maps and idempotence.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <libfdt.h>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <vector>
#define UKE_INIT
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
CPP
for header in uke-bwmon.h uke-cpu-bwmon.h uke-memlat.h; do
    printf '#include "%s/src/boot/%s"\n' "$root" "$header" >> "$work/check.cpp"
done
cat >> "$work/check.cpp" <<'CPP'
alignas(8) static char blob[16384];
static const char *path="/soc/qcom,memlat",*mon="/soc/qcom,bwmon-llcc@240B7300";
static int node(const char *p) { int n=fdt_path_offset(blob,p);assert(n>=0);return n; }
static void text(const char *p,const char *n,const char *v) { assert(!fdt_setprop_string(blob,node(p),n,v)); }
static void reset() {
    assert(!fdt_create_empty_tree(blob,sizeof(blob)));
    const char compatible[]="xiaomi,uke\0qcom,sm7675";
    assert(!fdt_setprop(blob,0,"compatible",compatible,sizeof(compatible)));
    assert(fdt_add_subnode(blob,0,"soc")>=0);
    assert(fdt_add_subnode(blob,node("/soc"),"qcom,memlat")>=0);
    text(path,"compatible","qcom,memlat");
    for(const char *name:{"llcc","l3","ddr","ddrqos"})assert(fdt_add_subnode(blob,node(path),name)>=0);
    const fdt32_t table[]={cpu_to_fdt32(902400),cpu_to_fdt32(300000)};
    assert(!fdt_setprop(blob,node("/soc/qcom,memlat/llcc"),"test-retained-map",table,sizeof(table)));
    assert(fdt_add_subnode(blob,node("/soc"),"qcom,bwmon-llcc@240B7300")>=0);
    text(mon,"compatible","qcom,sm7675-cpu-bwmon");
    fdt32_t paths[]={cpu_to_fdt32(10),cpu_to_fdt32(2),cpu_to_fdt32(3),cpu_to_fdt32(10),cpu_to_fdt32(555),cpu_to_fdt32(3),cpu_to_fdt32(11),0,cpu_to_fdt32(11),cpu_to_fdt32(1)};
    assert(!fdt_setprop(blob,node(mon),"interconnects",paths,sizeof(paths)));
}
int main() {
    reset();assert(!uke_memlat_apply(blob));assert(!uke_memlat_apply(blob));
    assert(!fdt_node_check_compatible(blob,node(path),"xiaomi,uke-memlat"));
    int a,b;const void *x=fdt_getprop(blob,node(path),"interconnects",&a),*y=fdt_getprop(blob,node(mon),"interconnects",&b);
    assert(x&&y&&a==40&&b==a&&!memcmp(x,y,a));
    x=fdt_getprop(blob,node(path),"interconnect-names",&a);assert(x&&a==8&&!memcmp(x,"llcc\0l3",8));
    x=fdt_getprop(blob,node("/soc/qcom,memlat/llcc"),"test-retained-map",&a);assert(x&&a==8);
    for(const char *name:{"/soc/qcom,memlat/ddr","/soc/qcom,memlat/ddrqos"})assert(node(name)>=0);
    for(unsigned i=0;i<10;i++) {
        reset();switch(i) {
        case 0:text("/","compatible","foreign,board");break;
        case 1:text(path,"compatible","foreign,memlat");break;
        case 2:text(mon,"compatible","qcom,bwmon4");break;
        case 3:text(mon,"status","disabled");break;
        case 4:assert(!fdt_delprop(blob,node(mon),"interconnects"));break;
        case 5:assert(!fdt_setprop_u32(blob,node(path),"qcom,cyc-ev",0x11));break;
        case 6:assert(!fdt_del_node(blob,node("/soc/qcom,memlat/l3")));break;
        case 7:assert(!fdt_setprop_u32(blob,node(path),"interconnects",0));break;
        case 8:text(path,"interconnect-names","foreign");break;
        case 9:text(path,"status","broken");break;
        }assert(uke_memlat_apply(blob)<0);
    }
    reset();text(path,"status","disabled");assert(!uke_memlat_apply(blob));assert(!fdt_node_check_compatible(blob,node(path),"qcom,memlat"));
    reset();assert(!fdt_del_node(blob,node(path)));assert(!uke_memlat_apply(blob));
    puts("Uke MEMLAT FDT: native paths, tags, retained maps, malformed graphs and idempotence pass; host only");
}
CPP
"${CXX:-clang++}" -std=c++17 -Wall -Wextra -Werror -Wno-unused-function -Wno-sign-compare -fsanitize=undefined,address -fno-sanitize-recover=all "$work/check.cpp" -lfdt -o "$work/check"
"$work/check"
