#!/usr/bin/env bash
# Native DDR conversion and all affected ICC tuples; no device/MMIO access.
set -Eeuo pipefail
project=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <libfdt.h>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <initializer_list>
#include <map>
#include <string>
#include <vector>
#define UKE_INIT
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
CPP
printf '#include "%s/src/boot/uke-bwmon.h"\n' "$project" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
static char fdt[2*1024*1024];
static const char *mon="/soc/qcom,bwmon-ddr@24091000",*mc="/soc/interconnect@1",*ddr="/soc/qcom,dcvs/ddr",*freq="/soc/ddr-freq-table";
static int node(const char *path) { int n=fdt_path_offset(fdt,path); assert(n>=0); return n; }
static void cells(const char *path,const char *name,std::initializer_list<unsigned> values) {
    std::vector<fdt32_t> v; for(auto x:values) v.push_back(cpu_to_fdt32(x));
    assert(!fdt_setprop(fdt,node(path),name,v.data(),v.size()*4));
}
static void text(const char *path,const char *name,const char *value) { assert(!fdt_setprop_string(fdt,node(path),name,value)); }
static void add(const char *parent,const char *name) { assert(fdt_add_subnode(fdt,node(parent),name)>=0); }
static unsigned first(const char *path,const char *name) { int bytes; auto *p=static_cast<const fdt32_t *>(fdt_getprop(fdt,node(path),name,&bytes)); assert(p&&bytes>=4); return fdt32_to_cpu(*p); }
static void expect(const char *path,const char *name,std::initializer_list<unsigned> values) {
    std::vector<unsigned> v(values); assert(!uke_bwmon_cells(fdt,node(path),name,v.data(),v.size()));
}
static void reset() {
    assert(!fdt_create_empty_tree(fdt,sizeof(fdt)));
    const char compat[]="xiaomi,uke\0qcom,sm7675";
    assert(!fdt_setprop(fdt,0,"compatible",compat,sizeof(compat)));
    add("/","soc"); cells("/soc","#address-cells",{1}); cells("/soc","#size-cells",{1});
    add("/soc","interconnect@1"); text(mc,"compatible","qcom,cliffs-mc_virt"); cells(mc,"phandle",{10}); cells(mc,"#interconnect-cells",{1});
    add("/soc","other-icc"); cells("/soc/other-icc","phandle",{11}); cells("/soc/other-icc","#interconnect-cells",{1});
    add("/soc","qcom,dcvs"); add("/soc/qcom,dcvs","ddr"); text(ddr,"compatible","qcom,dcvs-hw");
    cells(ddr,"phandle",{12}); cells(ddr,"qcom,dcvs-hw-type",{0}); cells(ddr,"qcom,bus-width",{4}); cells(ddr,"qcom,freq-tbl",{13});
    add(ddr,"sp"); cells("/soc/qcom,dcvs/ddr/sp","interconnects",{10,3,10,512});
    add("/soc","ddr-freq-table"); cells(freq,"phandle",{13}); cells(freq,"qcom,freq-tbl",{547000,768000,1555000,1708000,2092000,2736000,3187000,3686000,4224000});
    add("/soc","qcom,bwmon-ddr@24091000"); text(mon,"compatible","qcom,bwmon5"); cells(mon,"reg",{0x24091000,0x1000}); text(mon,"reg-names","base");
    cells(mon,"interrupts",{0,81,4}); cells(mon,"qcom,hw-timer-hz",{19200000}); cells(mon,"qcom,count-unit",{65536}); cells(mon,"qcom,target-dev",{12});
    add("/soc","usb"); cells("/soc/usb","interconnects",{11,49,10,512,10,3,11,547});
    add("/soc","qcom,bwmon-llcc@240B7300"); text("/soc/qcom,bwmon-llcc@240B7300","compatible","qcom,bwmon4"); cells("/soc/qcom,bwmon-llcc@240B7300","qcom,second-vote",{99});
}
static void valid() {
    assert(!uke_bwmon_apply(fdt));
    assert(!fdt_node_check_compatible(fdt,node(mon),"qcom,sm7675-llcc-bwmon"));
    assert(first(mc,"#interconnect-cells")==2);
    expect(mon,"interconnects",{10,3,3,10,512,3});
    expect("/soc/usb","interconnects",{11,49,10,512,0,10,3,0,11,547});
    expect("/soc/qcom,dcvs/ddr/sp","interconnects",{10,3,0,10,512,0});
    expect("/soc/qcom,bwmon-llcc@240B7300","qcom,second-vote",{99});
    assert(!fdt_node_check_compatible(fdt,node("/soc/qcom,bwmon-llcc@240B7300"),"qcom,bwmon4"));
    for(auto *prop:{"qcom,target-dev","qcom,count-unit","qcom,hw-timer-hz","reg-names"}) assert(!fdt_getprop(fdt,node(mon),prop,nullptr));
    int opps=fdt_subnode_offset(fdt,node(mon),"opp-table"),child,count=0;
    assert(opps>=0 && first(mon,"operating-points-v2")==fdt_get_phandle(fdt,opps));
    fdt_for_each_subnode(child,fdt,opps) count++;
    assert(count==9 && first("/soc/qcom,bwmon-ddr@24091000/opp-table/opp-547000","opp-peak-kBps")==2188000);
    assert(first("/soc/qcom,bwmon-ddr@24091000/opp-table/opp-4224000","opp-peak-kBps")==16896000);
    assert(!uke_bwmon_apply(fdt));
}
static std::map<std::string,std::vector<unsigned>> requests(const void *blob) {
    std::map<std::string,std::vector<unsigned>> result;
    unsigned int handle=fdt_get_phandle(blob,fdt_path_offset(blob,mc));
    for(int n=fdt_next_node(blob,-1,nullptr);n>=0;n=fdt_next_node(blob,n,nullptr)) {
        int bytes; auto *input=static_cast<const fdt32_t *>(fdt_getprop(blob,n,"interconnects",&bytes));
        if(!input) continue;
        assert(bytes>0 && bytes%4==0); char path[512]; assert(!fdt_get_path(blob,n,path,sizeof(path)));
        auto &values=result[path];
        for(unsigned int pos=0;pos<static_cast<unsigned int>(bytes/4);) {
            unsigned int phandle=fdt32_to_cpu(input[pos++]); int provider=fdt_node_offset_by_phandle(blob,phandle),len;
            auto *cells=static_cast<const fdt32_t *>(fdt_getprop(blob,provider,"#interconnect-cells",&len)); assert(cells&&len==4);
            unsigned int args=fdt32_to_cpu(*cells); assert(args<=16 && pos+args<=static_cast<unsigned int>(bytes/4));
            values.push_back(phandle); values.push_back(phandle==handle?2:args);
            for(unsigned int i=0;i<args;i++) values.push_back(fdt32_to_cpu(input[pos++]));
            if(phandle==handle && args==1) values.push_back(0);
        }
    }
    return result;
}
int main(int argc,char **argv) {
    if(argc==3) {
        std::ifstream input(argv[1],std::ios::binary); std::vector<char> raw((std::istreambuf_iterator<char>(input)),{});
        assert(!raw.empty() && !fdt_check_full(raw.data(),raw.size()));
        const auto before=requests(raw.data());
        assert(!fdt_open_into(raw.data(),fdt,sizeof(fdt)));
        int ret=uke_bwmon_apply(fdt); if(ret) { fprintf(stderr,"retained FDT refusal: %d (%s)\n",ret,fdt_strerror(ret)); return 1; }
        assert(!uke_bwmon_apply(fdt) && !fdt_check_full(fdt,sizeof(fdt)));
        const auto after=requests(fdt);
        for(const auto &[path,values]:before) assert(after.at(path)==values);
        std::ofstream output(argv[2],std::ios::binary); output.write(fdt,fdt_totalsize(fdt)); assert(output.good());
        printf("Retained Uke DDR BWMON: %zu existing ICC request properties preserve endpoints/tags, new AMC/WAKE-only path and idempotence passed; no hardware operation\n",before.size()); return 0;
    }
    assert(argc==1); reset(); valid();
    reset(); text(mon,"status","disabled"); valid(); int bytes; assert(!strcmp(static_cast<const char *>(fdt_getprop(fdt,node(mon),"status",&bytes)),"disabled"));
    reset(); assert(!fdt_del_node(fdt,node(mon))); assert(!uke_bwmon_apply(fdt)); assert(first(mc,"#interconnect-cells")==1);
    for(unsigned i=0;i<16;i++) {
        reset();
        switch(i) {
        case 0:text("/","compatible","foreign,board");break;
        case 1:cells(mon,"reg",{0x24091001,0x1000});break;
        case 2:cells(mon,"reg",{0x24091000,0x800});break;
        case 3:cells(mon,"interrupts",{0,82,4});break;
        case 4:cells(mon,"qcom,hw-timer-hz",{19000000});break;
        case 5:cells(mon,"qcom,count-unit",{64000});break;
        case 6:cells(mon,"qcom,target-dev",{13});break;
        case 7:cells(ddr,"qcom,bus-width",{8});break;
        case 8:cells(freq,"qcom,freq-tbl",{547000});break;
        case 9:cells("/soc/qcom,dcvs/ddr/sp","interconnects",{10,4,10,512});break;
        case 10:cells(mc,"#interconnect-cells",{3});break;
        case 11:cells("/soc/usb","interconnects",{99,3,10,512});break;
        case 12:cells("/soc/usb","interconnects",{10});break;
        case 13:cells(mon,"operating-points-v2",{77});break;
        case 14:text(mon,"status","broken");break;
        case 15:cells(ddr,"qcom,dcvs-hw-type",{1});break;
        }
        assert(uke_bwmon_apply(fdt)<0);
    }
    reset(); valid(); cells(mon,"interconnects",{10,3,0,10,512,0}); assert(uke_bwmon_apply(fdt)<0);
    reset(); valid(); cells(mon,"interconnects",{10,3,1,10,512,1}); assert(uke_bwmon_apply(fdt)<0);
    reset(); valid(); cells("/soc/qcom,bwmon-ddr@24091000/opp-table/opp-547000","opp-peak-kBps",{2086000}); assert(uke_bwmon_apply(fdt)<0);
    reset(); valid(); cells("/soc/qcom,bwmon-ddr@24091000/opp-table/opp-547000","opp-microvolt",{999}); assert(uke_bwmon_apply(fdt)<0);
    reset(); valid(); cells("/soc/qcom,bwmon-ddr@24091000/opp-table/opp-547000","opp-avg-kBps",{999}); assert(uke_bwmon_apply(fdt)<0);
    reset(); cells(mon,"clocks",{99}); assert(uke_bwmon_apply(fdt)<0);
    puts("Uke DDR BWMON: exact source resources/OPPs, AMC/WAKE tag, all prior MC tuples, 22 refusals, disabled/absent preservation and idempotence passed; host only");
}
CPP
"${CXX:-clang++}" -std=c++20 -O1 -g -Wall -Wextra -Werror \
    -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
    ${CPPFLAGS:-} "$work/check.cpp" ${LIBFDT_LIBS:--lfdt} -o "$work/check"
"$work/check" "$@"
