#!/usr/bin/env bash
# Execute the actual early selector with bounded FDT access stubs; no device I/O.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <string.h>
#include <stddef.h>
#define UKE_INIT
#define FDT_ERR_BADVALUE 15
static const char *bootargs;
static int bootargs_bytes, calls;
static void *used;
static int fdt_path_offset(const void *fdt,const char *path) {
    assert(fdt && !strcmp(path,"/chosen")); return 1;
}
static const void *fdt_getprop(const void *fdt,int node,const char *name,int *bytes) {
    assert(fdt && node==1 && !strcmp(name,"bootargs"));
    *bytes=bootargs_bytes; return bootargs;
}
static int fdt_check_header(const void *fdt) { return !fdt; }
static int uke_abl_native(void *fdt,void *overlay,size_t bytes,const char *selector) {
    assert(fdt && overlay && bytes==1 && selector); ++calls; used=overlay; return 7;
}
C
sed -n '/^struct uke_native_panel {/,/^\/\*$/p' "$root/src/display/uke-abl-native.h" | sed '$d' >> "$work/check.c"
sed -n '/^static inline int UKE_INIT uke_abl_native_select(/,$p' "$root/src/display/uke-abl-native.h" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
int main(void) {
    char fdt=0,a=0,b=0,args[1024];
    struct uke_native_panel panels[]={
        {"msm_drm.dsi_display0=qcom,mdss_dsi_o82_36_02_0a_dualdsi_dsc_vid",&a,1},
        {"msm_drm.dsi_display0=qcom,mdss_dsi_o82_42_02_0b_dualdsi_dsc_vid",&b,1}
    };
    for(unsigned int p=0;p<2;p++)for(unsigned int form=0;form<4;form++) {
        const char *suffix=form==0 ? "":form==1 ? ":":form==2 ? ":config0":"";
        size_t n=0;
        if(form==3) {strcpy(args,"console=tty0\t");n=strlen(args);}
        strcpy(args+n,panels[p].selector);strcat(args,suffix);strcat(args," quiet");
        bootargs=args;bootargs_bytes=strlen(args)+1;calls=0;
        assert(uke_abl_native_select(&fdt,panels,2)==7 && calls==1);
        assert(used==(p ? (void *)&b:(void *)&a));
    }
    static const char *invalid[]={"", "quiet", "msm_drm.dsi_display0=unknown",
        "xmsm_drm.dsi_display0=qcom,mdss_dsi_o82_36_02_0a_dualdsi_dsc_vid",
        "msm_drm.dsi_display0=qcom,mdss_dsi_o82_36_02_0a_dualdsi_dsc_vid_extra",
        "msm_drm.dsi_display0=qcom,mdss_dsi_o82_42_02_0b_dualdsi_dsc_vid_extra"};
    for(unsigned int i=0;i<sizeof(invalid)/sizeof(invalid[0]);i++) {
        bootargs=invalid[i];bootargs_bytes=strlen(bootargs)+1;calls=0;
        assert(uke_abl_native_select(&fdt,panels,2)<0 && !calls);
    }
    for(unsigned int p=0;p<2;p++) {
        strcpy(args,panels[0].selector);strcat(args," ");strcat(args,panels[p].selector);
        bootargs=args;bootargs_bytes=strlen(args)+1;calls=0;
        assert(uke_abl_native_select(&fdt,panels,2)<0 && !calls);
    }
    bootargs=panels[0].selector;bootargs_bytes=strlen(bootargs);calls=0;
    assert(uke_abl_native_select(&fdt,panels,2)<0 && !calls);
    static const char embedded[]="quiet\0msm_drm.dsi_display0=unknown";
    bootargs=embedded;bootargs_bytes=sizeof(embedded);
    assert(uke_abl_native_select(&fdt,panels,2)<0 && !calls);
    bootargs=NULL;bootargs_bytes=0;
    assert(uke_abl_native_select(&fdt,panels,2)<0 && !calls);
    assert(uke_abl_native_select(NULL,panels,2)<0 && !calls);
}
C
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror "$work/check.c" -o "$work/check"
"$work/check"
printf 'O82 early selector: both suppliers, colon forms, exact tokens, duplicates and malformed bootargs passed\n'
