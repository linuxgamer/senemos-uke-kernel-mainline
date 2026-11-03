#!/usr/bin/env bash
# Compile the actual Uke FDT helper against Linux's bundled host libfdt.
set -Eeuo pipefail
kernel=${1:?Pass prepared Linux source}
[[ -f $kernel/scripts/dtc/libfdt/libfdt.h ]]
project=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
awk '/^static int UKE_INIT uke_volume_down_wake\(/ {copy=1} copy {print} copy && /^}/ {exit}' \
    "$project/src/boot/uke-abl.c" > "$work/actual.c"
[[ -s $work/actual.c ]]
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <libfdt.h>
#define UKE_INIT
static unsigned char tree[4096], saved[4096];
static int fault;
static const char path[] = "/soc/qcom,spmi@c42d000/qcom,pmk8550@0/pon_hlos@1300/resin";
static int inject(void *f, int n, const char *p, const void *v, int l) {
    return fault ? -FDT_ERR_NOSPACE : fdt_setprop(f,n,p,v,l);
}
#define fdt_setprop inject
#include "actual.c"
#undef fdt_setprop
static int node(void) { int n=fdt_path_offset(tree,path); assert(n>=0); return n; }
static void reset(void) {
    fault=0;
    assert(!fdt_create_empty_tree(tree,sizeof(tree)));
    int n=0;
    const char *names[]={"soc","qcom,spmi@c42d000","qcom,pmk8550@0","pon_hlos@1300","resin"};
    for(unsigned i=0;i<sizeof(names)/sizeof(names[0]);i++) { n=fdt_add_subnode(tree,n,names[i]); assert(n>=0); }
    assert(!fdt_setprop_string(tree,n,"compatible","qcom,pmk8350-resin"));
    assert(!fdt_setprop_u32(tree,node(),"linux,code",114));
    const fdt32_t irq[]={cpu_to_fdt32(0),cpu_to_fdt32(0x13),cpu_to_fdt32(6),cpu_to_fdt32(3)};
    assert(!fdt_setprop(tree,node(),"interrupts",irq,sizeof(irq)));
    assert(!fdt_setprop_string(tree,node(),"preserved","untouched"));
    memcpy(saved,tree,sizeof(tree));
}
static void refused(void) {
    unsigned char before[sizeof(tree)]; memcpy(before,tree,sizeof(tree));
    assert(uke_volume_down_wake(tree)<0 && !memcmp(tree,before,sizeof(tree)));
}
int main(void) {
    reset(); assert(!uke_volume_down_wake(tree));
    int length=-1; assert(fdt_getprop(tree,node(),"wakeup-source",&length) && !length);
    assert(!strcmp(fdt_getprop(tree,node(),"preserved",NULL),"untouched"));
    const char *properties[]={"compatible","linux,code","interrupts"};
    for(unsigned i=0;i<sizeof(properties)/sizeof(properties[0]);i++) {
        int a,b; const void *x=fdt_getprop(saved,fdt_path_offset(saved,path),properties[i],&a);
        const void *y=fdt_getprop(tree,node(),properties[i],&b); assert(x && y && a==b && !memcmp(x,y,a));
    }
    assert(!uke_volume_down_wake(tree));
    reset(); fault=1; refused();
    reset(); assert(!fdt_del_node(tree,node())); refused();
    reset(); assert(!fdt_setprop_string(tree,node(),"compatible","qcom,pmk8350-pwrkey")); refused();
    reset(); assert(!fdt_setprop_u32(tree,node(),"linux,code",116)); refused();
    reset(); assert(!fdt_delprop(tree,node(),"interrupts")); refused();
    for(unsigned i=0;i<4;i++) {
        reset(); int size; fdt32_t irq[4]; memcpy(irq,fdt_getprop(tree,node(),"interrupts",&size),sizeof(irq));
        irq[i]=cpu_to_fdt32(fdt32_to_cpu(irq[i])+1);
        assert(!fdt_setprop(tree,node(),"interrupts",irq,sizeof(irq))); refused();
    }
    puts("Actual resin wake helper: exact OEM key/IRQ admission, property preservation, idempotence and write refusal passed; no hardware result");
}
C
lib=$kernel/scripts/dtc/libfdt
sources=(fdt.c fdt_ro.c fdt_wip.c fdt_sw.c fdt_rw.c fdt_strerror.c fdt_empty_tree.c fdt_addresses.c)
for i in "${!sources[@]}"; do sources[i]=$lib/${sources[i]}; done
"${CC:-gcc}" -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-sign-compare \
    -I "$lib" -I "$work" "$work/check.c" "${sources[@]}" -o "$work/check"
"$work/check"
