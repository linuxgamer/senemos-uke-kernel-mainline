// SPDX-License-Identifier: GPL-2.0-only
#include <libfdt.h>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <vector>
#define UKE_INIT
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#include "../src/boot/uke-hardware.h"

static int path(void *dt, const char *name) {
    int n=fdt_path_offset(dt,name);assert(n>=0);return n;
}
static const char *text(void *dt,const char *node,const char *property) {
    int bytes;auto value=static_cast<const char*>(fdt_getprop(dt,path(dt,node),property,&bytes));
    assert(value&&bytes>0&&!value[bytes-1]);return value;
}
static void protected_equal(const void *before,const void *after) {
    assert(fdt_num_mem_rsv(before)==fdt_num_mem_rsv(after));
    for(int i=0;i<fdt_num_mem_rsv(before);++i) {
        uint64_t ba,bs,aa,as;
        assert(!fdt_get_mem_rsv(before,i,&ba,&bs)&&!fdt_get_mem_rsv(after,i,&aa,&as));
        assert(ba==aa&&bs==as);
    }
    int node;
    for(node=fdt_next_node(before,-1,nullptr);node>=0;node=fdt_next_node(before,node,nullptr)) {
        char name[1024];assert(!fdt_get_path(before,node,name,sizeof name));
        const bool protected_node=uke_hardware_below(name,"/memory")||
            uke_hardware_below(name,"/reserved-memory")||uke_hardware_below(name,"/ddr-regions")||
            uke_hardware_below(name,"/firmware")||std::strstr(name,"/pinctrl@");
        if(!protected_node) continue;
        int target=fdt_path_offset(after,name);assert(target>=0);
        int prop;
        fdt_for_each_property_offset(prop,before,node) {
            int bytes,actual;const char *key;
            const void *value=fdt_getprop_by_offset(before,prop,&key,&bytes);
            assert(value&&bytes>=0);
            const void *other=fdt_getprop(after,target,key,&actual);
            assert(other&&actual==bytes&&!std::memcmp(value,other,bytes));
        }
    }
}
int main(int argc,char **argv) {
    std::vector<char> dt(2*1024*1024);
    assert(!fdt_create_empty_tree(dt.data(),dt.size()));
    const char compatible[]="xiaomi,uke\0qcom,sm7675";
    assert(!fdt_setprop(dt.data(),0,"compatible",compatible,sizeof compatible));
    assert(fdt_add_subnode(dt.data(),0,"cpus")>=0);
    for(unsigned i=0;i<8;i++) {
        char name[32];std::snprintf(name,sizeof name,"cpu@%x",i*0x100);
        assert(fdt_add_subnode(dt.data(),path(dt.data(),"/cpus"),name)>=0);
    }
    for(const char *name:{"memory","firmware","soc","__symbols__","aliases"})assert(fdt_add_subnode(dt.data(),0,name)>=0);
    assert(!fdt_setprop_u32(dt.data(),path(dt.data(),"/soc"),"#address-cells",1));
    assert(!fdt_setprop_u32(dt.data(),path(dt.data(),"/soc"),"#size-cells",1));
    const char *pmu="/soc/llcc-pmu@24095000";
    assert(fdt_add_subnode(dt.data(),path(dt.data(),"/soc"),"llcc-pmu@24095000")>=0);
    assert(!fdt_setprop_string(dt.data(),path(dt.data(),pmu),"compatible","qcom,llcc-pmu-ver2"));
    const fdt32_t pmu_reg[]={cpu_to_fdt32(0x24095000),cpu_to_fdt32(0x300)};
    assert(!fdt_setprop(dt.data(),path(dt.data(),pmu),"reg",pmu_reg,sizeof pmu_reg));
    assert(!fdt_setprop_string(dt.data(),path(dt.data(),pmu),"reg-names","lagg-base"));
    assert(!fdt_setprop_u64(dt.data(),path(dt.data(),"/memory"),"reg",0x8000000020000000ULL));
    assert(fdt_add_subnode(dt.data(),path(dt.data(),"/soc"),"remoteproc-adsp@03000000")>=0);
    assert(!fdt_setprop_u32(dt.data(),path(dt.data(),"/soc/remoteproc-adsp@03000000"),"phandle",42));
    assert(fdt_add_subnode(dt.data(),path(dt.data(),"/soc"),"xiaomi_fingerprint")>=0);
    assert(fdt_add_subnode(dt.data(),path(dt.data(),"/soc"),"qrng@10c3000")>=0);
    const char *rng="/soc/qrng@10c3000";
    assert(!fdt_setprop_string(dt.data(),path(dt.data(),rng),"compatible","qcom,msm-rng"));
    const fdt32_t rng_reg[]={cpu_to_fdt32(0x10c3000),cpu_to_fdt32(0x1000)};
    assert(!fdt_setprop(dt.data(),path(dt.data(),rng),"reg",rng_reg,sizeof rng_reg));
    assert(!fdt_setprop(dt.data(),path(dt.data(),rng),"qcom,no-qrng-config",nullptr,0));
    assert(!fdt_setprop(dt.data(),path(dt.data(),rng),"qcom,no-clock-support",nullptr,0));
    assert(fdt_add_subnode(dt.data(),path(dt.data(),"/soc"),"qcom,mdss_mdp@ae00000")>=0);
    const char *parent="/soc/qcom,mdss_mdp@ae00000";
    for(const char *name:{"unused-panel","referenced-panel","aliased-panel"}) {
        int n=fdt_add_subnode(dt.data(),path(dt.data(),parent),name);assert(n>=0);
        assert(!fdt_setprop_string(dt.data(),n,"qcom,mdss-dsi-panel-name",name));
    }
    int nested=fdt_add_subnode(dt.data(),path(dt.data(),"/soc/qcom,mdss_mdp@ae00000/referenced-panel"),"timings");assert(nested>=0);
    assert(!fdt_setprop_u32(dt.data(),nested,"phandle",0xdead));
    assert(!fdt_setprop_u32(dt.data(),path(dt.data(),"/soc"),"unknown-vendor-reference",0xdead));
    assert(!fdt_setprop_string(dt.data(),path(dt.data(),"/aliases"),"panel0","/soc/qcom,mdss_mdp@ae00000/aliased-panel"));
    assert(!fdt_setprop_string(dt.data(),path(dt.data(),"/__symbols__"),"old_panel","/soc/qcom,mdss_mdp@ae00000/unused-panel"));
    auto initial=dt;
    for(unsigned fault=0;fault<10;++fault) {
        auto bad=initial;int n=path(bad.data(),pmu);
        if(fault<3) {
            fdt32_t reg[]={cpu_to_fdt32(fault==0?0x24095004:0x24095000),cpu_to_fdt32(fault==1?0x1000:0x300)};
            assert(!fdt_setprop(bad.data(),n,"reg",reg,fault==2?4:sizeof reg));
        }
        if(fault==3)assert(!fdt_setprop_string(bad.data(),n,"compatible","qcom,llcc-pmu"));
        if(fault==4)assert(!fdt_setprop_string(bad.data(),n,"reg-names","base"));
        if(fault==5)assert(!fdt_setprop_u32(bad.data(),n,"interrupts",1));
        if(fault==6)assert(!fdt_setprop_string(bad.data(),n,"status","reserved"));
        if(fault==7)assert(!fdt_setprop_u32(bad.data(),path(bad.data(),"/soc"),"#address-cells",2));
        if(fault==8)assert(!fdt_setprop_u32(bad.data(),path(bad.data(),"/soc"),"#size-cells",2));
        if(fault==9)assert(fdt_add_subnode(bad.data(),n,"other")>=0);
        auto before=bad;assert(uke_hardware_llcc_pmu(bad.data())<0&&bad==before);
    }
    for(const char *status:{"disabled","ok","okay"}) {
        auto candidate=initial;
        assert(!fdt_setprop_string(candidate.data(),path(candidate.data(),pmu),"status",status));
        assert(!uke_hardware_llcc_pmu(candidate.data()));
        assert(!std::strcmp(text(candidate.data(),pmu,"status"),status));
        auto before=candidate;assert(!uke_hardware_llcc_pmu(candidate.data())&&candidate==before);
    }
    {
        auto absent=initial;assert(!fdt_del_node(absent.data(),path(absent.data(),pmu)));
        auto before=absent;assert(!uke_hardware_llcc_pmu(absent.data())&&absent==before);
    }
    for(unsigned fault=0;fault<8;++fault) {
        auto bad=initial;int n=path(bad.data(),rng);
        if(fault<3) {
            fdt32_t reg[]={cpu_to_fdt32(fault==0?0x10c4000:0x10c3000),cpu_to_fdt32(fault==1?0x2000:0x1000)};
            assert(!fdt_setprop(bad.data(),n,"reg",reg,fault==2?4:sizeof reg));
        }
        if(fault==3)assert(!fdt_delprop(bad.data(),n,"qcom,no-qrng-config"));
        if(fault==4)assert(!fdt_setprop_string(bad.data(),n,"compatible","other,rng"));
        if(fault==5)assert(!fdt_setprop_u32(bad.data(),n,"clocks",42));
        if(fault==6)assert(!fdt_setprop_u32(bad.data(),n,"qcom,no-clock-support",1));
        if(fault==7)assert(!fdt_setprop_string(bad.data(),n,"clock-names","core"));
        auto before=bad;assert(uke_hardware_names(bad.data())<0&&bad==before);
    }
    {
        auto disabled=initial;
        assert(!fdt_setprop_string(disabled.data(),path(disabled.data(),rng),"status","disabled"));
        assert(!uke_hardware_names(disabled.data()));
        assert(!std::strcmp(text(disabled.data(),rng,"status"),"disabled"));
    }
    assert(!uke_hardware_names(dt.data()));
    assert(!fdt_node_check_compatible(dt.data(),path(dt.data(),pmu),"qcom,sm7675-llcc-pmu"));
    assert(!std::strcmp(text(dt.data(),"/cpus","model"),"Qualcomm Snapdragon 7+ Gen 3"));
    assert(!std::strcmp(text(dt.data(),"/cpus/cpu@200","compatible"),"arm,cortex-a520"));
    assert(!std::strcmp(text(dt.data(),"/cpus/cpu@300","compatible"),"arm,cortex-a720"));
    assert(!std::strcmp(text(dt.data(),"/cpus/cpu@700","compatible"),"arm,cortex-x4"));
    assert(!std::strcmp(text(dt.data(),"/memory","model"),"LPDDR5X"));
    assert(!fdt_node_check_compatible(dt.data(),path(dt.data(),rng),"qcom,sm7675-trng"));
    assert(!fdt_node_check_compatible(dt.data(),path(dt.data(),rng),"qcom,trng"));
    assert(!fdt_getprop(dt.data(),path(dt.data(),rng),"qcom,no-qrng-config",nullptr));
    assert(!fdt_getprop(dt.data(),path(dt.data(),rng),"qcom,no-clock-support",nullptr));
    assert(!std::strcmp(text(dt.data(),"/firmware/uke-accessories","pen-model"),"Xiaomi Focus Pen"));
    int count=0,n;fdt_for_each_subnode(n,dt.data(),path(dt.data(),"/firmware/ssc-sensors")) {
        assert(!fdt_node_check_compatible(dt.data(),n,"xiaomi,uke-ssc-sensor"));
        assert(!fdt_getprop(dt.data(),n,"reg",nullptr));
        assert(!fdt_getprop(dt.data(),n,"gpios",nullptr));++count;
    }assert(count==9);
    assert(!uke_hardware_simplify(dt.data()));
    assert(fdt_path_offset(dt.data(),"/soc/xiaomi_fingerprint")==-FDT_ERR_NOTFOUND);
    assert(fdt_path_offset(dt.data(),"/soc/qcom,mdss_mdp@ae00000/unused-panel")==-FDT_ERR_NOTFOUND);
    assert(fdt_path_offset(dt.data(),"/soc/qcom,mdss_mdp@ae00000/referenced-panel")>=0);
    assert(fdt_path_offset(dt.data(),"/soc/qcom,mdss_mdp@ae00000/aliased-panel")>=0);
    assert(!fdt_getprop(dt.data(),path(dt.data(),"/__symbols__"),"old_panel",nullptr));
    assert(!uke_hardware_names(dt.data())&&!uke_hardware_simplify(dt.data()));
    protected_equal(initial.data(),dt.data());
    auto saved=dt;assert(!fdt_setprop_string(dt.data(),0,"compatible","other,board"));
    auto foreign=dt;assert(uke_hardware_names(dt.data())<0&&dt==foreign);dt=saved;
    if(argc==3) {
        std::ifstream input(argv[1],std::ios::binary);std::vector<char> data{std::istreambuf_iterator<char>(input),{}};
        assert(data.size()>=40&&!fdt_check_full(data.data(),data.size()));
        assert(!fdt_open_into(data.data(),dt.data(),dt.size()));
        assert(!uke_hardware_names(dt.data()));assert(!uke_hardware_simplify(dt.data()));
        protected_equal(data.data(),dt.data());
        assert(!fdt_pack(dt.data()));std::ofstream out(argv[2],std::ios::binary);
        out.write(dt.data(),fdt_totalsize(dt.data()));assert(out.good());
    } else assert(argc==1);
    std::puts("Hardware DT identity, SSC ownership, absent fingerprint, conservative pruning and foreign-board fixtures passed; host only.");
}
