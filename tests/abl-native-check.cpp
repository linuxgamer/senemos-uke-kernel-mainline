// SPDX-License-Identifier: GPL-2.0-only
// Regular-file host fixture; exercises the exact native candidate transform.
#include <libfdt.h>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <vector>
#define UKE_INIT
#include "../src/display/uke-abl-native.h"

using Bytes=std::vector<char>;
static Bytes blob(const char *path) {
    std::ifstream file(path,std::ios::binary);
    Bytes result{std::istreambuf_iterator<char>(file),{}};
    assert(result.size()>=40 && result.size()<=2*1024*1024);
    assert(fdt_check_full(result.data(),result.size())==0);
    return result;
}
int main(int argc,char **argv) {
    assert(argc==4);
    const auto original=blob(argv[1]), overlay=blob(argv[2]);
    constexpr auto selected="msm_drm.dsi_display0=qcom,mdss_dsi_o82_42_02_0b_dualdsi_dsc_vid:";
    const auto prepare=[&] {
        Bytes fdt(2*1024*1024);
        assert(fdt_open_into(original.data(),fdt.data(),fdt.size())==0);
        return fdt;
    };
    auto fdt=prepare(), staged=overlay;
    const int result=uke_abl_native(fdt.data(),staged.data(),staged.size(),selected);
    if(result) std::fprintf(stderr,"Native entry refused: %d\n",result);
    assert(result==0);
    int bytes=0;
    const auto *framebuffer=static_cast<const char *>(fdt_getprop(fdt.data(),fdt_path_offset(fdt.data(),"/chosen"),"stdout-path",&bytes));
    assert(framebuffer && bytes>0 && !framebuffer[bytes-1]);
    const int fb=fdt_path_offset(fdt.data(),framebuffer);
    const auto *status=static_cast<const char *>(fdt_getprop(fdt.data(),fb,"status",&bytes));
    assert(status && bytes==5 && !std::strcmp(status,"okay"));
    assert(!fdt_getprop(fdt.data(),fb,"backlight",&bytes));
    assert(fdt_path_offset(fdt.data(),"/soc/display-subsystem@ae00000/dsi@ae94000/panel@0")>=0);
    /* Speaker amplifiers have no OEM labels: the entry must publish symbols and phandles for them. */
    {
        static const char *const labels[]={"uke_amp_tl","uke_amp_tr","uke_amp_bl","uke_amp_br"};
        const int symbols=fdt_path_offset(fdt.data(),"/__symbols__");
        assert(symbols>=0);
        for(unsigned i=0;i<4;i++) {
            char path[96];
            std::snprintf(path,sizeof path,"/soc/qcom,qupv3_1_geni_se@8c0000/i2c@88c000/fs19xx_smartpa@%x",0x34+i);
            if(fdt_path_offset(original.data(),path)<0) continue;
            const auto *symbol=static_cast<const char *>(fdt_getprop(fdt.data(),symbols,labels[i],&bytes));
            assert(symbol && !std::strcmp(symbol,path));
            assert(fdt_get_phandle(fdt.data(),fdt_path_offset(fdt.data(),path))!=0);
            /* A second, active-high description of the reset line would make gpiolib share it. */
            assert(!fdt_getprop(fdt.data(),fdt_path_offset(fdt.data(),path),"reset-gpio",&bytes));
        }
    }
    std::ofstream output(argv[3],std::ios::binary);
    output.write(fdt.data(),fdt_totalsize(fdt.data()));
    assert(output.good());
    for(unsigned fault=0;fault<7;fault++) {
        fdt=prepare(); staged=overlay;
        const char *selector=selected;
        if(fault==0) selector="msm_drm.dsi_display0=foreign-panel:";
        if(fault==1) assert(fdt_setprop_string(fdt.data(),0,"compatible","foreign,board")==0);
        if(fault==2) assert(fdt_setprop_string(fdt.data(),fdt_path_offset(fdt.data(),"/chosen"),"stdout-path","/soc/not-framebuffer")==0);
        if(fault==3) staged[0]=0;
        if(fault==4) assert(fdt_del_node(fdt.data(),fdt_path_offset(fdt.data(),"/__symbols__"))==0);
        if(fault==5) assert(fdt_del_node(fdt.data(),fdt_path_offset(fdt.data(),"/soc/display_gpio_regulator_vsp"))==0);
        if(fault==6) assert(fdt_del_node(fdt.data(),fdt_path_offset(fdt.data(),"/soc/display_gpio_regulator_vsn"))==0);
        const auto before=fdt;
        assert(uke_abl_native(fdt.data(),staged.data(),staged.size(),selector)<0);
        assert(fdt==before);
    }
}
