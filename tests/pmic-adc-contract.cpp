// SPDX-License-Identifier: GPL-2.0-only
// Host fixture for resource admission, standard consumers and refusal paths.
#include <libfdt.h>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <vector>
extern "C" int uke_pmic_adc_test(void *);
extern "C" int uke_cpu_thermal_test(void *);
using Blob = std::vector<unsigned char>;
static constexpr char adc_path[] = "/soc/qcom,spmi@c42d000/qcom,pmk8550@0/vadc@9000";
static const unsigned ids[] = {
    0x000,0x001,0x003,0x044,0x203,0x303,0x100,0x101,0x103,0x18e,
    0x700,0x701,0x703,0x78e,0x710,0x717,0x7a1,0x744,
    0x145,0x147,0x148,0x14c,0x14d,0x74b,0x74c,0x749,0x747
};
static const char *zones[] = {"xo-therm","cpu_therm","quiet_therm","flash_therm","display_therm","conn_therm2","wifi_therm","backlight_therm","charger_therm0","conn_therm"};
static const unsigned thermistors[] = {0x44,0x145,0x147,0x148,0x14c,0x14d,0x74c,0x74b,0x749,0x747};
static int add(void *fdt, int parent, const char *name) {
    int node=fdt_add_subnode(fdt,parent,name); assert(node>=0); return node;
}
static Blob fixture() {
    Blob b(32768); assert(!fdt_create_empty_tree(b.data(),b.size()));
    int n=add(b.data(),0,"soc"); n=add(b.data(),n,"qcom,spmi@c42d000");
    n=add(b.data(),n,"qcom,pmk8550@0"); n=add(b.data(),n,"vadc@9000");
    assert(!fdt_setprop_string(b.data(),n,"compatible","qcom,spmi-adc5-gen3"));
    assert(!fdt_setprop_u32(b.data(),n,"phandle",0x12));
    fdt32_t reg[]={cpu_to_fdt32(0x9000),cpu_to_fdt32(0x9100)};
    assert(!fdt_setprop(b.data(),n,"reg",reg,sizeof(reg)));
    for (unsigned id:ids) {
        n=fdt_path_offset(b.data(),adc_path); char name[32]; std::snprintf(name,sizeof(name),"oem-sensor@%x",id);
        int child=add(b.data(),n,name);
        assert(!fdt_setprop_u32(b.data(),child,"reg",id));
        assert(!fdt_setprop_u32(b.data(),child,"qcom,adc-tm-type",1));
        assert(!fdt_setprop_string(b.data(),child,"label",name));
        if(id==0x744) assert(!fdt_setprop_u32(b.data(),child,"qcom,scale-fn-type",23));
    }
    add(b.data(),0,"thermal-zones");
    n=add(b.data(),0,"pmic-glink");
    assert(!fdt_setprop_string(b.data(),n,"compatible","xiaomi,uke-pmic-glink"));
    for (unsigned i=0;i<10;i++) {
        n=add(b.data(),fdt_path_offset(b.data(),"/thermal-zones"),zones[i]);
        fdt32_t sensor[]={cpu_to_fdt32(0x12),cpu_to_fdt32(thermistors[i])};
        assert(!fdt_setprop(b.data(),n,"thermal-sensors",sensor,sizeof(sensor)));
        assert(!fdt_setprop_u32(b.data(),n,"polling-delay",0));
    }
    return b;
}
static constexpr const char *cpu_zones[] = {
    "cpu-0-1-0", "cpu-0-2-0", "cpu-1-0-0", "cpu-1-0-1",
    "cpu-1-1-0", "cpu-1-1-1", "cpu-1-2-0", "cpu-1-2-1",
    "cpu-1-3-0", "cpu-1-3-1", "cpu-2-0-0", "cpu-2-0-1", "cpu-2-0-2"
};
static constexpr unsigned cpu_ids[] = {1,2,3,3,4,4,5,5,6,6,7,7,7};
static Blob cpu_fixture() {
    Blob b(32768); auto f=b.data(); assert(!fdt_create_empty_tree(f,b.size()));
    add(f,0,"cpus"); add(f,0,"thermal-zones");
    int n=add(f,0,"soc"); add(f,n,"qcom,cpu-pause");
    char path[112], name[64];
    for(unsigned cpu=0;cpu<8;cpu++) {
        std::snprintf(name,sizeof(name),"cpu@%x",cpu*0x100);
        n=add(f,fdt_path_offset(f,"/cpus"),name);
        assert(!fdt_setprop_u32(f,n,"phandle",0x100+cpu));
        assert(!fdt_setprop_u32(f,n,"#cooling-cells",2));
        std::snprintf(name,sizeof(name),"cpu%u-pause",cpu);
        n=add(f,fdt_path_offset(f,"/soc/qcom,cpu-pause"),name);
        assert(!fdt_setprop_u32(f,n,"phandle",0x200+cpu));
        assert(!fdt_setprop_u32(f,n,"qcom,cpus",0x100+cpu));
    }
    for(unsigned i=0;i<13;i++) {
        n=add(f,fdt_path_offset(f,"/thermal-zones"),cpu_zones[i]);
        n=add(f,n,"trips"); n=add(f,n,"emergency");
        assert(!fdt_setprop_u32(f,n,"phandle",0x300+i));
        assert(!fdt_setprop_u32(f,n,"temperature",110000));
        assert(!fdt_setprop_u32(f,n,"hysteresis",cpu_ids[i]<3 ? 8000 : 10000));
        assert(!fdt_setprop_string(f,n,"type","passive"));
        std::snprintf(path,sizeof(path),"/thermal-zones/%s",cpu_zones[i]);
        n=add(f,fdt_path_offset(f,path),"cooling-maps"); n=add(f,n,"cpu");
        assert(!fdt_setprop_u32(f,n,"trip",0x300+i));
        fdt32_t cooling[]={cpu_to_fdt32(0x200+cpu_ids[i]),cpu_to_fdt32(1),cpu_to_fdt32(1)};
        assert(!fdt_setprop(f,n,"cooling-device",cooling,sizeof(cooling)));
    }
    return b;
}
static void cpu_test() {
    auto base=cpu_fixture(), b=base;
    assert(!uke_cpu_thermal_test(b.data()));
    for(unsigned i=0;i<13;i++) {
        char path[112]; std::snprintf(path,sizeof(path),"/thermal-zones/%s/cooling-maps/cpu",cpu_zones[i]);
        int bytes, n=fdt_path_offset(b.data(),path);
        auto map=static_cast<const fdt32_t *>(fdt_getprop(b.data(),n,"cooling-device",&bytes));
        assert(map && bytes==12 && fdt32_to_cpu(map[0])==0x100+(cpu_ids[i]<3 ? 0U : cpu_ids[i]<7 ? 3U : 7U));
        assert(fdt32_to_cpu(map[1])==0xffffffffU && fdt32_to_cpu(map[2])==0xffffffffU);
    }
    for(unsigned fault=0;fault<4;fault++) {
        b=base; int n;
        if(fault==0) { n=fdt_node_offset_by_phandle(b.data(),0x300); assert(!fdt_setprop_u32(b.data(),n,"temperature",45000)); }
        if(fault==1) { n=fdt_node_offset_by_phandle(b.data(),0x201); assert(!fdt_setprop_u32(b.data(),n,"qcom,cpus",0x107)); }
        if(fault==2) { n=fdt_node_offset_by_phandle(b.data(),0x100); assert(!fdt_setprop_u32(b.data(),n,"#cooling-cells",1)); }
        if(fault==3) { n=fdt_node_offset_by_phandle(b.data(),0x300); assert(!fdt_setprop_string(b.data(),n,"type","critical")); }
        assert(uke_cpu_thermal_test(b.data())<0);
    }
    std::puts("Thirteen native CPU emergency maps and four incompatible-resource refusals passed");
}
int main(int argc,char **argv) {
    cpu_test();
    if(argc==2 && argv[1][0]) {
        std::ifstream input(argv[1],std::ios::binary);
        Blob raw{std::istreambuf_iterator<char>(input),{}}; assert(!raw.empty());
        Blob expanded(raw.size()+65536); assert(!fdt_open_into(raw.data(),expanded.data(),expanded.size()));
        int endpoint=add(expanded.data(),0,"pmic-glink");
        assert(!fdt_setprop_string(expanded.data(),endpoint,"compatible","xiaomi,uke-pmic-glink"));
        assert(!uke_cpu_thermal_test(expanded.data()));
        assert(!uke_pmic_adc_test(expanded.data()));
        std::puts("Exact OEM CPU thermal and PMIC graph admitted");
    }
    auto base=fixture(), b=base;
    assert(!uke_pmic_adc_test(b.data()));
    int adc=fdt_path_offset(b.data(),adc_path), child, count=0;
    fdt_for_each_subnode(child,b.data(),adc) {
        assert(!std::strncmp(fdt_get_name(b.data(),child,nullptr),"channel@",8));
        assert(!fdt_getprop(b.data(),child,"qcom,adc-tm-type",nullptr)); count++;
    }
    assert(count==27);
    int batt=fdt_path_offset(b.data(),"/soc/qcom,spmi@c42d000/qcom,pmk8550@0/vadc@9000/channel@744");
    assert(batt>=0 && fdt_getprop(b.data(),batt,"qcom,adc5-gen3-batt-therm-100k",nullptr));
    assert(!fdt_getprop(b.data(),batt,"qcom,scale-fn-type",nullptr));
    int bytes=0, hwmon=fdt_path_offset(b.data(),"/pmic-adc-hwmon");
    assert(!fdt_node_check_compatible(b.data(),hwmon,"iio-hwmon"));
    auto channels=static_cast<const fdt32_t *>(fdt_getprop(b.data(),hwmon,"io-channels",&bytes));
    assert(channels && bytes==27*8);
    for (unsigned i=0;i<10;i++) {
        char path[80]; std::snprintf(path,sizeof(path),"/thermal-zones/%s",zones[i]);
        int zone=fdt_path_offset(b.data(),path);
        auto link=static_cast<const fdt32_t *>(fdt_getprop(b.data(),zone,"thermal-sensors",&bytes));
        assert(link && bytes==4);
        int sensor=fdt_node_offset_by_phandle(b.data(),fdt32_to_cpu(*link));
        assert(!fdt_node_check_compatible(b.data(),sensor,"generic-adc-thermal"));
        auto io=static_cast<const fdt32_t *>(fdt_getprop(b.data(),sensor,"io-channels",&bytes));
        assert(io && bytes==8 && fdt32_to_cpu(io[0])==0x12 && fdt32_to_cpu(io[1])==thermistors[i]);
        assert(!fdt_getprop(b.data(),sensor,"temperature-lookup-table",nullptr));
        auto delay=static_cast<const fdt32_t *>(fdt_getprop(b.data(),zone,"polling-delay",&bytes));
        assert(delay && bytes==4 && fdt32_to_cpu(*delay)==((i==5 || i>=8)?1000U:0U));
        if(i==5 || i>=8) {
            delay=static_cast<const fdt32_t *>(fdt_getprop(b.data(),zone,"polling-delay-passive",&bytes));
            assert(delay && bytes==4 && fdt32_to_cpu(*delay)==1000);
        }
    }
    int endpoint=fdt_path_offset(b.data(),"/pmic-glink");
    channels=static_cast<const fdt32_t *>(fdt_getprop(b.data(),endpoint,"io-channels",&bytes));
    assert(channels && bytes==24);
    for(unsigned i=0;i<3;i++) {
        const unsigned expected[]={0x749,0x747,0x14d};
        assert(fdt32_to_cpu(channels[2*i])==0x12 && fdt32_to_cpu(channels[2*i+1])==expected[i]);
    }
    assert(fdt_stringlist_count(b.data(),endpoint,"io-channel-names")==3);
    b=base; assert(!fdt_del_node(b.data(),fdt_path_offset(b.data(),"/pmic-glink")));
    assert(uke_pmic_adc_test(b.data())<0);
    for (unsigned bad=0;bad<6;bad++) {
        b=base; adc=fdt_path_offset(b.data(),adc_path);
        int first=fdt_first_subnode(b.data(),adc), second=fdt_next_subnode(b.data(),first);
        if (bad==0) assert(!fdt_del_node(b.data(),first));
        if (bad==1) {
            auto reg=fdt_getprop(b.data(),first,"reg",nullptr);
            fdt32_t duplicate=*static_cast<const fdt32_t *>(reg);
            assert(!fdt_setprop(b.data(),second,"reg",&duplicate,4));
        }
        if (bad==2) assert(!fdt_setprop_u32(b.data(),first,"reg",0x666));
        if (bad==3) assert(!fdt_setprop_string(b.data(),adc,"compatible","qcom,foreign-adc"));
        if (bad==4) assert(!fdt_setprop_u32(b.data(),adc,"reg",0x9000));
        if (bad==5) {
            int battery=fdt_path_offset(b.data(),"/soc/qcom,spmi@c42d000/qcom,pmk8550@0/vadc@9000/oem-sensor@744");
            assert(!fdt_setprop_u32(b.data(),battery,"qcom,scale-fn-type",8));
        }
        assert(uke_pmic_adc_test(b.data())<0);
    }
    std::puts("PMIC ADC: 27 IIO/hwmon channels, ten thermal consumers and six malformed-resource refusals passed");
}
