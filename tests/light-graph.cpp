// SPDX-License-Identifier: GPL-2.0-only
#include <libfdt.h>
#include "uke-lights.h"
#include <cassert>
#include <fstream>
#include <iterator>
#include <vector>
int main(int argc,char** argv) {
    assert(argc==2);std::ifstream in(argv[1],std::ios::binary);
    const std::vector<char> original{std::istreambuf_iterator<char>(in),{}};
    assert(!original.empty() && !fdt_check_full(original.data(),original.size()));
    assert(uke_lights_admitted(original.data()));
    std::vector<char> tree(original.size()+65536);
    auto reset=[&]{assert(!fdt_open_into(original.data(),tree.data(),tree.size()));};
    auto node=[&](const char* path){int n=fdt_path_offset(tree.data(),path);assert(n>=0);return n;};
    for(unsigned current:{0U,249U,251U,500U}) {
        reset();assert(!fdt_setprop_u32(tree.data(),node(UKE_LIGHT_FLASH "/qcom,torch_0"),"qcom,max-current-ma",current));
        assert(!uke_lights_admitted(tree.data()));
    }
    reset();assert(!fdt_setprop_u32(tree.data(),node(UKE_LIGHT_FLASH "/qcom,torch_3"),"qcom,id",2));assert(!uke_lights_admitted(tree.data()));
    reset();assert(!fdt_setprop_u32(tree.data(),node("/soc/qcom,camera-flash0"),"torch-source",0));assert(!uke_lights_admitted(tree.data()));
    reset();assert(!fdt_setprop_u32(tree.data(),node(UKE_LIGHT_PMIC "/qcom,leds@ef00/blue"),"led-sources",0));assert(!uke_lights_admitted(tree.data()));
    reset();assert(!fdt_delprop(tree.data(),node(UKE_LIGHT_FLASH),"compatible"));assert(!uke_lights_admitted(tree.data()));
    reset();assert(!fdt_setprop_u32(tree.data(),node(UKE_LIGHT_PMIC "/pwms@e800"),"reg",0xe900));assert(!uke_lights_admitted(tree.data()));
    reset();assert(uke_lights_admitted(tree.data()));
}
