#!/usr/bin/env bash
# COPR native fixture. Only synthetic FDT bytes are changed.
set -Eeuo pipefail
kernel=$(realpath "${1:?prepared kernel}")
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
cat > "$work/test.c" <<'C'
#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <libfdt.h>
#define UKE_INIT
#include "uke-rtc.h"
static _Alignas(8) char tree[8192],before[8192];
static const char *path="/soc/qcom,spmi@c42d000/qcom,pmk8550@0/rtc@6100";
static int rtc(void){int n=fdt_path_offset(tree,path);assert(n>=0);return n;}
static void reset(void){
 assert(!fdt_create_empty_tree(tree,sizeof(tree)));
 const char compatible[]="xiaomi,uke\0qcom,sm7675";
 assert(!fdt_setprop(tree,0,"compatible",compatible,sizeof(compatible)));
 int a=fdt_add_subnode(tree,0,"soc");assert(a>=0);
 int b=fdt_add_subnode(tree,a,"qcom,spmi@c42d000");assert(b>=0);
 int c=fdt_add_subnode(tree,b,"qcom,pmk8550@0");assert(c>=0);
 int d=fdt_add_subnode(tree,c,"rtc@6100");assert(d>=0);
 assert(!fdt_setprop_string(tree,d,"compatible","qcom,pmk8350-rtc"));
 fdt32_t reg[]={cpu_to_fdt32(0x6100),cpu_to_fdt32(0x6200)};
 assert(!fdt_setprop(tree,rtc(),"reg",reg,sizeof(reg)));
}
int main(void){
 reset();assert(!uke_rtc_secure_offset(tree));assert(fdt_getprop(tree,rtc(),"qcom,uefi-rtc-info",NULL));
 memcpy(before,tree,sizeof(tree));assert(!uke_rtc_secure_offset(tree));assert(!memcmp(before,tree,sizeof(tree)));
 const char *forbidden[]={"allow-set-time","nvmem-cells","nvmem-cell-names"};
 for(unsigned i=0;i<3;i++){reset();assert(!fdt_setprop_u32(tree,rtc(),forbidden[i],1));memcpy(before,tree,sizeof(tree));assert(uke_rtc_secure_offset(tree)<0);assert(!memcmp(before,tree,sizeof(tree)));}
 reset();assert(!fdt_setprop_string(tree,0,"compatible","xiaomi,other"));memcpy(before,tree,sizeof(tree));assert(uke_rtc_secure_offset(tree)<0&&!memcmp(before,tree,sizeof(tree)));
 reset();assert(!fdt_setprop_u32(tree,rtc(),"reg",0x6100));memcpy(before,tree,sizeof(tree));assert(uke_rtc_secure_offset(tree)<0&&!memcmp(before,tree,sizeof(tree)));
 reset();assert(!fdt_setprop_string(tree,rtc(),"compatible","qcom,pm8941-rtc"));memcpy(before,tree,sizeof(tree));assert(uke_rtc_secure_offset(tree)<0&&!memcmp(before,tree,sizeof(tree)));
 puts("RTC FDT: exact Uke/SM7675 and PMK resource admission, idempotence and foreign/direct-write/offset conflicts passed; synthetic FDT only");
}
C
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -UNDEBUG -I"$kernel/arch/arm64/kernel" "$work/test.c" -lfdt -o "$work/check"
"$work/check"
