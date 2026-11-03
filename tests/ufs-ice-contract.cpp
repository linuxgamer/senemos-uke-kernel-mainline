// SPDX-License-Identifier: GPL-2.0-only
#include <libfdt.h>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <vector>
#define UKE_INIT
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#include "../src/boot/uke-ufs.h"

static int node(void *dt, const char *path) {
    int n=fdt_path_offset(dt,path);assert(n>=0);return n;
}
int main(int argc,char **argv) {
    std::vector<char> dt(65536);
    assert(!fdt_create_empty_tree(dt.data(),dt.size()));
    int soc=fdt_add_subnode(dt.data(),0,"soc");assert(soc>=0);
    int host=fdt_add_subnode(dt.data(),soc,"ufshc@1d84000");assert(host>=0);
    const char *path="/soc/ufshc@1d84000";
    assert(!fdt_setprop_string(dt.data(),host,"compatible","qcom,ufshc"));
    const unsigned ranges[]={0x1d84000,0x3000,0x1d88000,0x8000,0x1d90000,0x9000,0x1da5000,0x2000,0x1da4000,0x10};
    fdt32_t reg[ARRAY_SIZE(ranges)];
    for(unsigned i=0;i<ARRAY_SIZE(ranges);i++)reg[i]=cpu_to_fdt32(ranges[i]);
    assert(!fdt_setprop(dt.data(),host,"reg",reg,sizeof reg));
    const char names[]="ufs_mem\0ufs_ice\0ufs_ice_hwkm\0mcq_sqd\0mcq_vs";
    assert(!fdt_setprop(dt.data(),host,"reg-names",names,sizeof names));
    assert(!fdt_setprop_u32(dt.data(),host,"shared-ice-cfg",42));
    int config=fdt_add_subnode(dt.data(),node(dt.data(),"/soc"),"shared_ice");assert(config>=0);
    assert(!fdt_setprop_u32(dt.data(),config,"phandle",42));
    int alg=fdt_add_subnode(dt.data(),config,"alg3");assert(alg>=0);
    assert(!fdt_setprop_string(dt.data(),alg,"status","ok"));
    fdt32_t cores[]={cpu_to_fdt32(28),cpu_to_fdt32(28),cpu_to_fdt32(15),cpu_to_fdt32(13)};
    assert(!fdt_setprop(dt.data(),alg,"num-core",cores,sizeof cores));
    for(const char *name:{"alg1","alg2"}) {
        int other=fdt_add_subnode(dt.data(),node(dt.data(),"/soc/shared_ice"),name);assert(other>=0);
        assert(!fdt_setprop_string(dt.data(),other,"status","disabled"));
    }
    const auto initial=dt;
    assert(!uke_ufs_admit(dt.data())&&dt==initial);
    for(unsigned fault=0;fault<ARRAY_SIZE(reg)+10;fault++) {
        dt=initial;host=node(dt.data(),path);alg=node(dt.data(),"/soc/shared_ice/alg3");
        if(fault<ARRAY_SIZE(reg)) {
            auto changed=std::vector<fdt32_t>(reg,reg+ARRAY_SIZE(reg));
            changed[fault]=cpu_to_fdt32(ranges[fault]+1);
            assert(!fdt_setprop(dt.data(),host,"reg",changed.data(),sizeof reg));
        }
        if(fault==10)assert(!fdt_setprop(dt.data(),host,"reg",reg,sizeof reg-4));
        if(fault==11)assert(!fdt_setprop_string(dt.data(),host,"reg-names","std"));
        if(fault==12)assert(!fdt_setprop_u32(dt.data(),host,"shared-ice-cfg",43));
        if(fault==13)assert(!fdt_delprop(dt.data(),host,"shared-ice-cfg"));
        if(fault==14)assert(!fdt_setprop_string(dt.data(),alg,"status","disabled"));
        if(fault==15)assert(!fdt_setprop(dt.data(),alg,"num-core",cores,sizeof cores-4));
        if(fault==16)assert(!fdt_setprop_u32(dt.data(),alg,"num-core",32));
        if(fault==17)assert(!fdt_setprop_string(dt.data(),host,"compatible","foreign,ufs"));
        if(fault==18) {
            fdt32_t changed[]={cpu_to_fdt32(28),cpu_to_fdt32(28),cpu_to_fdt32(15),cpu_to_fdt32(14)};
            assert(!fdt_setprop(dt.data(),alg,"num-core",changed,sizeof changed));
        }
        if(fault==19) {
            int other=node(dt.data(),"/soc/shared_ice/alg2");
            assert(!fdt_setprop_string(dt.data(),other,"status","okay"));
        }
        const auto before=dt;assert(uke_ufs_admit(dt.data())<0&&dt==before);
    }
    if(argc==2) {
        std::ifstream input(argv[1],std::ios::binary);
        std::vector<char> real{std::istreambuf_iterator<char>(input),{}};
        assert(real.size()>=40&&!fdt_check_full(real.data(),real.size()));
        assert(!uke_ufs_admit(real.data()));
    } else assert(argc==1);
    std::puts("UFS ICE exact OEM resources/allocator and 20 refusal fixtures passed; host only");
}
