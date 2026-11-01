#!/usr/bin/env bash
# Execute the prepared boot helper on synthetic and optional retained DT copies.
set -Eeuo pipefail
kernel=$(realpath "${1:?Pass kernel source with the installed boot helper}")
project=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libfdt.h>
#define UKE_INIT
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#include "uke-clock-debug.h"
static _Alignas(8) char fdt[2*1024*1024], before[sizeof(fdt)];
static const char *paths[]={
 "/soc/rsc@17a00000/drv@2/clock-controller","/soc/clock-controller@ade0000",
 "/soc/clock-controller@af00000","/soc/clock-controller@100000",
 "/soc/clock-controller@3d90000","/soc/clock-controller@aaf0000"};
static int node(const char *path) { int n=fdt_path_offset(fdt,path);assert(n>=0);return n; }
static void add(const char *parent,const char *name) { assert(fdt_add_subnode(fdt,node(parent),name)>=0); }
static void text(const char *path,const char *name,const char *value) { assert(!fdt_setprop_string(fdt,node(path),name,value)); }
static void cell(const char *path,const char *name,unsigned value) { assert(!fdt_setprop_u32(fdt,node(path),name,value)); }
static void reset(void) {
 memset(fdt,0,sizeof(fdt));assert(!fdt_create_empty_tree(fdt,sizeof(fdt)));
 const char compat[]="xiaomi,uke\0qcom,sm7675";
 assert(!fdt_setprop(fdt,0,"compatible",compat,sizeof(compat)));
 add("/","soc");add("/soc","rsc@17a00000");add("/soc/rsc@17a00000","drv@2");
 add("/soc/rsc@17a00000/drv@2","clock-controller");
 for(unsigned i=1;i<ARRAY_SIZE(paths);i++)add("/soc",strrchr(paths[i],'/')+1);
 for(unsigned i=0;i<ARRAY_SIZE(paths);i++) {cell(paths[i],"phandle",i+1);cell(paths[i],"#clock-cells",1);}
 add("/soc","clock-controller@0");const char *debug="/soc/clock-controller@0";
 text(debug,"compatible","qcom,cliffs-debugcc");cell(debug,"phandle",77);cell(debug,"#clock-cells",1);
 fdt32_t refs[12];for(unsigned i=0;i<6;i++){refs[2*i]=cpu_to_fdt32(i+1);refs[2*i+1]=0;}
 assert(!fdt_setprop(fdt,node(debug),"clocks",refs,sizeof(refs)));
 const char names[]="xo_clk_src\0camcc\0dispcc\0gcc\0gpucc\0videocc";
 assert(!fdt_setprop(fdt,node(debug),"clock-names",names,sizeof(names)));
}
static void refused(void) {memcpy(before,fdt,sizeof(fdt));assert(uke_clock_debug_retire(fdt)<0);assert(!memcmp(before,fdt,sizeof(fdt)));}
int main(int argc,char **argv) {
 const char *debug="/soc/clock-controller@0";
 reset();assert(!uke_clock_debug_retire(fdt));
 assert(!strcmp(fdt_getprop(fdt,node(debug),"status",NULL),"disabled"));
 memcpy(before,fdt,sizeof(fdt));assert(!uke_clock_debug_retire(fdt));assert(!memcmp(before,fdt,sizeof(fdt)));
 for(unsigned fault=0;fault<11;fault++) {
  reset();switch(fault) {
   case 0:text(debug,"compatible","qcom,other-debugcc");break;
   case 1:cell(debug,"reg",0);break;
   case 2:cell(debug,"#clock-cells",0);break;
   case 3:cell(debug,"phandle",0);break;
   case 4:text(debug,"clock-names","xo_clk_src");break;
   case 5:cell(debug,"clocks",1);break;
   case 6:cell(paths[3],"#clock-cells",2);break;
   case 7:cell(paths[4],"phandle",22);break;
   case 8:text(debug,"status","reserved");break;
   case 9:add("/soc","unexpected-debug");text("/soc/unexpected-debug","compatible","qcom,cliffs-debugcc");break;
   case 10:add("/soc","consumer");cell("/soc/consumer","qcom,unknown-reference",77);break;
  }refused();
 }
 reset();text("/","compatible","qcom,foreign");memcpy(before,fdt,sizeof(fdt));
 assert(!uke_clock_debug_retire(fdt)&&!memcmp(before,fdt,sizeof(fdt)));
 reset();assert(!fdt_del_node(fdt,node(debug)));memcpy(before,fdt,sizeof(fdt));
 assert(!uke_clock_debug_retire(fdt)&&!memcmp(before,fdt,sizeof(fdt)));
 if(argc==2) {
  FILE *input=fopen(argv[1],"rb");assert(input);
  size_t bytes=fread(before,1,sizeof(before),input);assert(!ferror(input)&&feof(input));fclose(input);
  assert(!fdt_check_full(before,bytes));assert(!fdt_open_into(before,fdt,sizeof(fdt)));
  assert(!uke_clock_debug_retire(fdt));assert(!fdt_check_full(fdt,sizeof(fdt)));
  assert(!strcmp(fdt_getprop(fdt,node(debug),"status",NULL),"disabled"));
 }
 puts("PASS: exact debugcc admission, 11 faults, foreign/absent/idempotent copies; no hardware state changed");
}
C
lib=$kernel/scripts/dtc/libfdt
sources=(fdt.c fdt_ro.c fdt_wip.c fdt_sw.c fdt_rw.c fdt_strerror.c fdt_empty_tree.c fdt_addresses.c)
for i in "${!sources[@]}"; do sources[i]=$lib/${sources[i]}; done
[[ $(sha256sum "$project/src/boot/vendor/fdt_check.c" | cut -d ' ' -f1) == "$(jq -er .sha256 "$project/src/boot/vendor/source.json")" ]]
sources+=("$project/src/boot/vendor/fdt_check.c")
"${CC:-cc}" -std=gnu11 -O1 -Wall -Wextra -Werror -Wno-sign-compare \
    -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
    -I "$lib" -I "$kernel/arch/arm64/kernel" "$work/check.c" "${sources[@]}" -o "$work/check"
"$work/check" "${@:2}"
