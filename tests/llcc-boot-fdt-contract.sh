#!/usr/bin/env bash
# Actual boot helper with Linux's bundled host libfdt; no boot/image operations.
set -Eeuo pipefail
kernel=${1:?Pass prepared Linux source}
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/kernel" "$work/output"
set +e
UKE_LLCC_PROFILE=unreviewed bash "$project/src/boot/prepare-abl-source.sh" \
    "$work/kernel" "$work/output" > "$work/profile.log" 2>&1
result=$?
set -e
[[ $result == 2 && -z $(find "$work/output" -mindepth 1 -print -quit) ]]
grep -Fxq 'Unknown LLCC source profile' "$work/profile.log"
set +e
UKE_LLCC_PROFILE=native-v1 bash "$project/src/boot/prepare-abl-source.sh" \
    "$work/kernel" "$work/output" > "$work/source-lock.log" 2>&1
result=$?
set -e
[[ $result != 0 && -z $(find "$work/output" -mindepth 1 -print -quit) ]]
grep -q 'source-lock.json' "$work/source-lock.log"
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <libfdt.h>
#define UKE_INIT
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
static int writes, fault;
static int setprop(void *f, int n, const char *p, const void *v, int l) {
    if (++writes==fault) return -FDT_ERR_BADSTATE;
    return fdt_setprop(f,n,p,v,l);
}
static int delprop(void *f, int n, const char *p) {
    if (++writes==fault) return -FDT_ERR_BADSTATE;
    return fdt_delprop(f,n,p);
}
static int delnode(void *f, int n) {
    if (++writes==fault) return -FDT_ERR_BADSTATE;
    return fdt_del_node(f,n);
}
#define fdt_setprop setprop
#define fdt_delprop delprop
#define fdt_del_node delnode
#include "uke-llcc.h"
#undef fdt_setprop
#undef fdt_delprop
#undef fdt_del_node
static unsigned char source[4096], before[4096], output[8192];
static int path(const void *f, const char *p) { int n=fdt_path_offset(f,p); assert(n>=0); return n; }
static void reset(void) {
    writes=fault=0;
    assert(!fdt_create_empty_tree(source,sizeof(source)));
    assert(fdt_add_subnode(source,0,"chosen")>=0);
    assert(!fdt_setprop_string(source,path(source,"/chosen"),"bootargs","preserve-me"));
    assert(fdt_add_subnode(source,0,"soc")>=0);
    int soc=path(source,"/soc");
    assert(!fdt_setprop_u32(source,soc,"#address-cells",1));
    assert(!fdt_setprop_u32(source,soc,"#size-cells",1));
    assert(fdt_add_subnode(source,soc,"cache-controller@25000000")>=0);
    int node=path(source,UKE_LLCC_PATH);
    const char compat[]="qcom,cliffs7-llcc\0qcom,llcc-v50", names[]="llcc_base\0llcc_broadcast_base";
    const fdt32_t regs[]={cpu_to_fdt32(0x25000000),cpu_to_fdt32(0x800000),cpu_to_fdt32(0x25800000),cpu_to_fdt32(0x200000)};
    const fdt32_t irq[]={cpu_to_fdt32(0),cpu_to_fdt32(266),cpu_to_fdt32(4)};
    assert(!fdt_setprop(source,node,"compatible",compat,sizeof(compat)));
    assert(!fdt_setprop(source,node,"reg-names",names,sizeof(names)));
    assert(!fdt_setprop(source,node,"reg",regs,sizeof(regs)));
    assert(!fdt_setprop(source,node,"interrupts",irq,sizeof(irq)));
    assert(!fdt_setprop_u32(source,node,"phandle",77));
    assert(!fdt_setprop_string(source,node,"label","cache_cont"));
    assert(!fdt_setprop(source,node,"cap-based-alloc-and-pwr-collapse",NULL,0));
    assert(fdt_add_subnode(source,node,"llcc-perfmon")>=0);
    memcpy(before,source,sizeof(source));
}
static void scratch(void) { assert(!fdt_open_into(source,output,sizeof(output))); }
static void unchanged(void) { assert(!memcmp(source,before,sizeof(source))); }
int main(void) {
    int length;
    reset(); assert(!uke_llcc_admit(source)); scratch(); assert(!uke_llcc_apply(output));
    unchanged(); assert(writes==7 && !fdt_check_full(output,sizeof(output)));
    int node=path(output,UKE_LLCC_PATH);
    assert(!strcmp(fdt_getprop(output,node,"compatible",NULL),"qcom,sm7675-llcc"));
    assert(!strcmp(fdt_getprop(output,node,"status",NULL),"okay"));
    assert(fdt_get_phandle(output,node)==77);
    const fdt32_t *regs=fdt_getprop(output,node,"reg",&length);
    assert(regs && length==40);
    for(unsigned int i=0;i<5;i++) {
        assert(fdt32_to_cpu(regs[2*i])==0x25000000+i*0x200000);
        assert(fdt32_to_cpu(regs[2*i+1])==0x200000);
    }
    assert(!fdt_getprop(output,node,"label",&length) && length==-FDT_ERR_NOTFOUND);
    assert(fdt_subnode_offset(output,node,"llcc-perfmon")==-FDT_ERR_NOTFOUND);
    assert(!strcmp(fdt_getprop(output,path(output,"/chosen"),"bootargs",NULL),"preserve-me"));
    for(int i=1;i<=7;i++) {
        reset(); scratch(); fault=i;
        assert(uke_llcc_apply(output)==-FDT_ERR_BADSTATE && writes==i); unchanged();
    }
    for(int i=0;i<8;i++) {
        reset(); node=path(source,UKE_LLCC_PATH);
        switch(i) {
        case 0: assert(!fdt_setprop_string(source,node,"compatible","qcom,cliffs-llcc")); break;
        case 1: assert(!fdt_setprop_u32(source,path(source,"/soc"),"#address-cells",2)); break;
        case 2: assert(!fdt_setprop_u32(source,node,"reg",0x25000004)); break;
        case 3: assert(!fdt_setprop_string(source,node,"reg-names","llcc0_base")); break;
        case 4: assert(!fdt_setprop_u32(source,node,"interrupts",0)); break;
        case 5: assert(!fdt_setprop_string(source,node,"status","disabled")); break;
        case 6: assert(fdt_add_subnode(source,node,"unexpected")>=0); break;
        case 7: assert(!fdt_delprop(source,path(source,"/soc"),"#size-cells")); break;
        }
        memcpy(before,source,sizeof(source));
        assert(uke_llcc_admit(source)==-FDT_ERR_BADVALUE); scratch();
        assert(uke_llcc_apply(output)==-FDT_ERR_BADVALUE && !writes); unchanged();
    }
    reset(); node=path(source,UKE_LLCC_PATH); assert(!fdt_setprop_string(source,node,"status","ok"));
    memcpy(before,source,sizeof(source)); scratch(); assert(!uke_llcc_apply(output)); unchanged();
    reset(); node=path(source,UKE_LLCC_PATH);
    assert(!fdt_del_node(source,fdt_subnode_offset(source,node,"llcc-perfmon")));
    assert(!fdt_delprop(source,node,"label"));
    assert(!fdt_delprop(source,node,"cap-based-alloc-and-pwr-collapse"));
    memcpy(before,source,sizeof(source)); scratch(); assert(!uke_llcc_apply(output)); unchanged();
    int failed=0,passed=0;
    reset(); assert(!fdt_pack(source)); memcpy(before,source,sizeof(source));
    int packed=fdt_totalsize(source);
    for(int room=0;room<256;room++) {
        assert(!fdt_open_into(source,output,packed+room)); writes=fault=0;
        int ret=uke_llcc_apply(output);
        if(ret) { assert(ret==-FDT_ERR_NOSPACE); failed++; } else passed++;
        unchanged();
    }
    assert(failed && passed);
    puts("Actual boot LLCC helper: admission, seven write faults, bounded space, input/sentinels and optional metadata passed");
}
C
lib=$kernel/scripts/dtc/libfdt
sources=(fdt.c fdt_ro.c fdt_wip.c fdt_sw.c fdt_rw.c fdt_strerror.c fdt_empty_tree.c fdt_addresses.c)
for i in "${!sources[@]}"; do sources[i]=$lib/${sources[i]}; done
# Linux omits this matching DTC validator until native source preparation.
grep -Fq 'DTC 1.7.2-g53373d13' "$kernel/scripts/dtc/version_gen.h"
[[ $(sha256sum "$project/src/boot/vendor/fdt_check.c" | cut -d ' ' -f1) == "$(jq -er .sha256 "$project/src/boot/vendor/source.json")" ]]
sources+=("$project/src/boot/vendor/fdt_check.c")
"${CC:-gcc}" -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-sign-compare \
    ${LLCC_TEST_CFLAGS:-} -I "$lib" -I "$project/src/boot" "$work/check.c" "${sources[@]}" -o "$work/check"
"$work/check"
