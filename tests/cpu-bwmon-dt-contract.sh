#!/usr/bin/env bash
# Exact native CPU/LLCC and L3 FDT admission, with no device/MMIO access.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
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
printf '#include "%s/src/boot/uke-bwmon.h"\n#include "%s/src/boot/uke-cpu-bwmon.h"\n' "$root" "$root" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
alignas(8) static char fdt[2*1024*1024];
static const char *mon="/soc/qcom,bwmon-llcc@240B7300",*gem="/soc/interconnect@24100000",*llcc="/soc/qcom,dcvs/llcc",*freq="/soc/llcc-freq-table",*vote="/soc/qcom,llcc-l3-vote",*l3="/soc/qcom,dcvs/l3",*native_l3="/soc/interconnect@17d90000",*cpu="/soc/qcom,cpufreq-hw",*xo="/soc/rsc@17a00000/drv@2/clock-controller",*gcc="/soc/clock-controller@100000";
static int node(const char *path) { int n=fdt_path_offset(fdt,path);assert(n>=0);return n; }
static void cells(const char *path,const char *name,std::initializer_list<unsigned> vals) {
    std::vector<fdt32_t> wire;for(auto x:vals)wire.push_back(cpu_to_fdt32(x));
    assert(!fdt_setprop(fdt,node(path),name,wire.data(),wire.size()*4));
}
static void text(const char *path,const char *name,const char *value) { assert(!fdt_setprop_string(fdt,node(path),name,value)); }
static void add(const char *parent,const char *name) { assert(fdt_add_subnode(fdt,node(parent),name)>=0); }
static unsigned first(const char *path,const char *name) { int bytes;auto *p=static_cast<const fdt32_t *>(fdt_getprop(fdt,node(path),name,&bytes));assert(p&&bytes>=4);return fdt32_to_cpu(*p); }
static void expect(const char *path,const char *name,std::initializer_list<unsigned> vals) { std::vector<unsigned> v(vals);assert(!uke_bwmon_cells(fdt,node(path),name,v.data(),v.size())); }
static void reset() {
    assert(!fdt_create_empty_tree(fdt,sizeof(fdt)));const char compat[]="xiaomi,uke\0qcom,sm7675";
    assert(!fdt_setprop(fdt,0,"compatible",compat,sizeof(compat)));add("/","soc");cells("/soc","#address-cells",{1});cells("/soc","#size-cells",{1});
    add("/soc","interconnect@24100000");text(gem,"compatible","qcom,cliffs-gem_noc");cells(gem,"phandle",{10});cells(gem,"#interconnect-cells",{1});
    add("/soc","other-icc");cells("/soc/other-icc","phandle",{11});cells("/soc/other-icc","#interconnect-cells",{2});
    add("/soc","qcom,dcvs");add("/soc/qcom,dcvs","llcc");text(llcc,"compatible","qcom,dcvs-hw");cells(llcc,"phandle",{12});cells(llcc,"qcom,dcvs-hw-type",{1});cells(llcc,"qcom,bus-width",{16});cells(llcc,"qcom,freq-tbl",{13});add(llcc,"sp");cells("/soc/qcom,dcvs/llcc/sp","interconnects",{10,2,10,555});
    add("/soc","llcc-freq-table");cells(freq,"phandle",{13});cells(freq,"qcom,freq-tbl",{300000,466500,600000,806000,933000,1066000});
    add("/soc/qcom,dcvs","l3");text(l3,"compatible","qcom,dcvs-hw");cells(l3,"phandle",{14});cells(l3,"qcom,dcvs-hw-type",{2});cells(l3,"qcom,bus-width",{32});cells(l3,"reg",{0x17d90000,0x4000,0x17d90100,0xa0});
    add(l3,"sp");cells("/soc/qcom,dcvs/l3/sp","qcom,dcvs-path-type",{0});cells("/soc/qcom,dcvs/l3/sp","qcom,shared-offset",{0x90});
    add("/soc","qcom,llcc-l3-vote");cells(vote,"phandle",{15});cells(vote,"qcom,target-dev",{14});cells(vote,"qcom,secondary-map",{300000,364800,466500,518400,600000,614400,806000,806400,933000,902400,1066000,998400});
    add("/soc","qcom,cpufreq-hw");text(cpu,"compatible","qcom,cpufreq-epss");cells(cpu,"reg",{0x17d91000,0x1000,0x17d92000,0x1000,0x17d93000,0x1000});cells(cpu,"clocks",{16,0,17,0});assert(!fdt_setprop(fdt,node(cpu),"clock-names","xo\0alternate",sizeof("xo\0alternate")));
    add("/soc","rsc@17a00000");add("/soc/rsc@17a00000","drv@2");add("/soc/rsc@17a00000/drv@2","clock-controller");text(xo,"compatible","qcom,cliffs-rpmh-clk");cells(xo,"phandle",{16});cells(xo,"#clock-cells",{1});
    add("/soc","clock-controller@100000");text(gcc,"compatible","qcom,cliffs-gcc");cells(gcc,"phandle",{17});cells(gcc,"#clock-cells",{1});
    add("/soc","qcom,bwmon-llcc@240B7300");text(mon,"compatible","qcom,bwmon4");cells(mon,"reg",{0x240b7400,0x300,0x240b7300,0x200});text(mon,"reg-names","base");cells(mon,"interrupts",{0,581,4});cells(mon,"qcom,mport",{0});cells(mon,"qcom,hw-timer-hz",{19200000});cells(mon,"qcom,count-unit",{65536});cells(mon,"qcom,target-dev",{12});cells(mon,"qcom,second-vote",{15});
    add("/soc","usb");cells("/soc/usb","interconnects",{11,49,7,10,555,10,2,11,547,3});
}
static void valid() {
    int ret=uke_cpu_bwmon_apply(fdt);if(ret)fprintf(stderr,"CPU FDT returned %d\n",ret);assert(!ret);
    assert(!fdt_node_check_compatible(fdt,node(mon),"qcom,sm7675-cpu-bwmon"));
    expect(mon,"reg",{0x240b7400,0x300});expect(native_l3,"reg",{0x17d90000,0x1000});expect(native_l3,"clocks",{16,0,17,0});
    unsigned h=fdt_get_phandle(fdt,node(native_l3));assert(h);
    expect(mon,"interconnects",{10,2,3,10,555,3,h,0,h,1});expect(gem,"#interconnect-cells",{2});
    expect("/soc/usb","interconnects",{11,49,7,10,555,0,10,2,0,11,547,3});
    expect("/soc/qcom,dcvs/llcc/sp","interconnects",{10,2,0,10,555,0});
    int opps=fdt_subnode_offset(fdt,node(mon),"opp-table"),child,count=0;assert(opps>=0);
    assert(first(mon,"operating-points-v2")==fdt_get_phandle(fdt,opps));fdt_for_each_subnode(child,fdt,opps)count++;assert(count==6);
    const unsigned ll[]={300000,466500,600000,806000,933000,1066000},l[]={364800,518400,614400,806400,902400,998400};
    for(unsigned i=0;i<6;i++) { std::string p=std::string(mon)+"/opp-table/opp-"+std::to_string(ll[i]);expect(p.c_str(),"opp-peak-kBps",{ll[i]*16,l[i]*32}); }
    for(const char *p:{"reg-names","qcom,mport","qcom,hw-timer-hz","qcom,count-unit","qcom,target-dev","qcom,second-vote"})assert(!fdt_getprop(fdt,node(mon),p,nullptr));
    assert(!uke_cpu_bwmon_apply(fdt));
}
static std::map<std::string,std::vector<unsigned>> requests(const void *blob) {
    std::map<std::string,std::vector<unsigned>> result;
    unsigned g=fdt_get_phandle(blob,fdt_path_offset(blob,gem));
    for(int n=fdt_next_node(blob,-1,nullptr);n>=0;n=fdt_next_node(blob,n,nullptr)) {
        int bytes;auto *p=static_cast<const fdt32_t *>(fdt_getprop(blob,n,"interconnects",&bytes));if(!p)continue;
        assert(bytes>0&&bytes%4==0);char path[512];assert(!fdt_get_path(blob,n,path,sizeof(path)));auto &v=result[path];
        for(unsigned pos=0;pos<static_cast<unsigned>(bytes/4);) {
            unsigned h=fdt32_to_cpu(p[pos++]);int provider=fdt_node_offset_by_phandle(blob,h),len;
            auto *a=static_cast<const fdt32_t *>(fdt_getprop(blob,provider,"#interconnect-cells",&len));assert(a&&len==4);unsigned args=fdt32_to_cpu(*a);assert(args<=16&&pos+args<=static_cast<unsigned>(bytes/4));
            v.push_back(h);v.push_back(h==g?2:args);for(unsigned i=0;i<args;i++)v.push_back(fdt32_to_cpu(p[pos++]));if(h==g&&args==1)v.push_back(0);
        }
    }
    return result;
}
int main(int argc,char **argv) {
    if(argc==3) {
        std::ifstream in(argv[1],std::ios::binary);std::vector<char> raw((std::istreambuf_iterator<char>(in)),{});assert(!raw.empty()&&!fdt_check_full(raw.data(),raw.size()));
        auto before=requests(raw.data());assert(!fdt_open_into(raw.data(),fdt,sizeof(fdt)));int ret=uke_cpu_bwmon_apply(fdt);if(ret){fprintf(stderr,"retained CPU refusal: %d (%s)\n",ret,fdt_strerror(ret));return 1;}
        auto after=requests(fdt);for(const auto &[path,values]:before)assert(after.at(path)==values);assert(!uke_cpu_bwmon_apply(fdt)&&!fdt_check_full(fdt,sizeof(fdt)));
        std::ofstream out(argv[2],std::ios::binary);out.write(fdt,fdt_totalsize(fdt));assert(out.good());printf("Retained CPU/L3 FDT: %zu existing ICC properties preserve endpoints/tags; paired OPPs and idempotence pass; host only\n",before.size());return 0;
    }
    assert(argc==1);reset();valid();
    reset();text(mon,"status","disabled");assert(!uke_cpu_bwmon_apply(fdt));assert(fdt_path_offset(fdt,native_l3)==-FDT_ERR_NOTFOUND);expect(gem,"#interconnect-cells",{1});
    reset();assert(!fdt_del_node(fdt,node(mon)));assert(!uke_cpu_bwmon_apply(fdt));
    for(unsigned i=0;i<29;i++) {
        reset();switch(i) {
        case 0:text("/","compatible","foreign,board");break;
        case 1:cells(mon,"reg",{0x240b7401,0x300,0x240b7300,0x200});break;
        case 2:cells(mon,"reg",{0x240b7400,0x300,0x240b7200,0x200});break;
        case 3:cells(mon,"interrupts",{0,582,4});break;
        case 4:cells(mon,"qcom,mport",{1});break;
        case 5:cells(mon,"qcom,hw-timer-hz",{19000000});break;
        case 6:cells(mon,"qcom,count-unit",{64000});break;
        case 7:cells(mon,"qcom,target-dev",{13});break;
        case 8:cells(mon,"qcom,second-vote",{14});break;
        case 9:cells(llcc,"qcom,bus-width",{8});break;
        case 10:cells(llcc,"qcom,dcvs-hw-type",{0});break;
        case 11:cells(freq,"qcom,freq-tbl",{300000});break;
        case 12:cells(vote,"qcom,secondary-map",{300000,364800});break;
        case 13:cells(vote,"qcom,target-dev",{13});break;
        case 14:cells(l3,"reg",{0x17d90000,0x3000,0x17d90100,0xa0});break;
        case 15:cells(l3,"qcom,bus-width",{16});break;
        case 16:cells("/soc/qcom,dcvs/l3/sp","qcom,shared-offset",{0x320});break;
        case 17:cells(cpu,"clocks",{16,0,17,1});break;
        case 18:text(cpu,"clock-names","alternate");break;
        case 19:cells(cpu,"reg",{0x17d90000,0x4000});break;
        case 20:cells(gem,"#interconnect-cells",{3});break;
        case 21:cells("/soc/usb","interconnects",{99,3});break;
        case 22:cells(mon,"operating-points-v2",{77});break;
        case 23:text(mon,"status","broken");break;
        case 24:add("/soc","interconnect@17d90000");break;
        case 25:cells(mon,"clocks",{99});break;
        case 26:text(gcc,"status","disabled");break;
        case 27:cells(xo,"#clock-cells",{0});break;
        case 28:cells("/soc/qcom,dcvs/llcc/sp","interconnects",{10,2,10,554});break;
        }assert(uke_cpu_bwmon_apply(fdt)<0);
    }
    for(unsigned i=0;i<8;i++) {
        reset();valid();switch(i) {
        case 0:cells(mon,"interconnects",{10,2,3,10,555,3});break;
        case 1:cells(native_l3,"reg",{0x17d90000,0x4000});break;
        case 2:cells(native_l3,"clocks",{16,0,17,1});break;
        case 3:cells((std::string(mon)+"/opp-table/opp-466500").c_str(),"opp-peak-kBps",{7110000,16588800});break;
        case 4:cells((std::string(mon)+"/opp-table/opp-300000").c_str(),"opp-avg-kBps",{1,1});break;
        case 5:text(native_l3,"status","disabled");break;
        case 6:cells(mon,"qcom,second-vote",{15});break;
        case 7:add(native_l3,"unexpected");break;
        }assert(uke_cpu_bwmon_apply(fdt)<0);
    }
    printf("CPU/L3 FDT: six paired exact OPPs, clocks/resources, all GEM tags, 37 refusals, absent/disabled and idempotence pass; host only\n");
}
CPP
"${CXX:-clang++}" -std=c++20 -O1 -g -Wall -Wextra -Werror -Wno-unused-function \
    -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
    ${CPPFLAGS:-} "$work/check.cpp" ${LIBFDT_LIBS:--lfdt} -o "$work/check"
"$work/check" "$@"
