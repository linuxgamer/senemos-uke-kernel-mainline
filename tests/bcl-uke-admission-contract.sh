#!/usr/bin/env bash
# Actual Uke legacy-DT and read-only revision admission; no device access.
set -Eeuo pipefail
source=${1:?Pass prepared qcom-bcl-hwmon.c}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>
using u8=uint8_t;using u32=uint32_t;
#define ARRAY_SIZE(a) int(sizeof(a)/sizeof((a)[0]))
struct device_node {
    device_node *parent=nullptr;
    const char *compatible="qcom,bcl-v5";
    std::map<std::string,std::vector<u32>> cells;
    std::map<std::string,std::vector<std::string>> strings;
};
struct device { device_node *of_node; device *parent=nullptr; };
struct regmap {};
struct bcl_device { struct regmap *regmap; u32 base=0x4700; };
static device_node pmic,node,other,*path_node;
static bool machine,sm7675;
static int of_gets,of_puts,steps,fail_at,reads,bad_reg;
static u32 values[0x10];
static const char *const bcl_uke_int_names[]={"bcl-lvl0","bcl-lvl1","bcl-lvl2"};
static bool fail() { return ++steps==fail_at; }
static bool of_machine_is_compatible(const char *s) { return !strcmp(s,"xiaomi,uke")?machine:sm7675; }
static bool of_device_is_compatible(device_node *n,const char *s) { return n&&!strcmp(n->compatible,s); }
static device_node *of_find_node_by_path(const char *s) {
    assert(!strcmp(s,"/soc/qcom,spmi@c42d000/qcom,pm7550ba@7/bcl@4700"));
    if(path_node)of_gets++;
    return path_node;
}
static void of_node_put(device_node *n) { if(n)of_puts++; }
static bool of_property_present(device_node *n,const char *s) { return n->cells.contains(s)||n->strings.contains(s); }
static int of_property_count_u32_elems(device_node *n,const char *s) {
    auto it=n->cells.find(s);return it==n->cells.end()?-EINVAL:int(it->second.size());
}
static int of_property_read_u32_array(device_node *n,const char *s,u32 *v,int count) {
    if(fail())return -EIO;
    assert(of_property_count_u32_elems(n,s)==count);
    memcpy(v,n->cells.at(s).data(),count*sizeof(*v));return 0;
}
static int of_property_count_strings(device_node *n,const char *s) {
    auto it=n->strings.find(s);return it==n->strings.end()?-EINVAL:int(it->second.size());
}
static int of_property_read_string_index(device_node *n,const char *s,int i,const char **v) {
    if(fail())return -EIO;
    *v=n->strings.at(s).at(i).c_str();return 0;
}
static int regmap_read(regmap *,unsigned int reg,unsigned int *v) {
    reads++;assert(reg>=0x4700&&reg<0x4710);
    if(int(reg-0x4700)==bad_reg)return -EIO;
    *v=values[reg-0x4700];return 0;
}
CPP
awk '/^static bool bcl_legacy_uke_match/{p=1} /^static const struct reg_field bcl_pm7250b_reg_fields/{p=0} p{print}' "$source" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
static void reset() {
    assert(of_gets==of_puts);of_gets=of_puts=steps=reads=fail_at=0;bad_reg=-1;machine=sm7675=true;
    pmic={};pmic.compatible="qcom,spmi-pmic";pmic.cells["reg"]={7,0};node={};node.parent=&pmic;
    node.cells["reg"]={0x4700,0x100};node.cells["interrupts"]={7,0x47,0,0,7,0x47,1,0,7,0x47,2,0};
    node.strings["interrupt-names"]={"bcl-lvl0","bcl-lvl1","bcl-lvl2"};path_node=&node;
}
int main() {
    reset();device parent{&pmic},dev{&node,&parent};assert(bcl_legacy_uke_match(&dev));int total=steps;
    for(int f=1;f<=total;f++) { reset();fail_at=f;assert(!bcl_legacy_uke_match(&dev)&&!reads&&of_gets==of_puts); }
    for(int m=0;m<15;m++) {
        reset();dev.parent=&parent;parent.of_node=&pmic;
        switch(m) {
        case 0:machine=false;break;case 1:sm7675=false;break;
        case 2:node.compatible="qcom,pm7550ba-bcl";break;
        case 3:path_node=&other;break;case 4:path_node=nullptr;break;
        case 5:dev.parent=nullptr;break;case 6:parent.of_node=&other;break;
        case 7:pmic.compatible="other";break;case 8:pmic.cells["reg"]={6,0};break;
        case 9:node.cells["reg"]={0x4800,0x100};break;
        case 10:node.cells["interrupts"][6]=2;break;
        case 11:node.strings["interrupt-names"][1]="critical";break;
        case 12:node.cells["interrupt-parent"]={1};break;
        case 13:pmic.cells["interrupt-parent"]={1};break;
        case 14:node.cells["interrupts-extended"]={1};break;
        }
        assert(!bcl_legacy_uke_match(&dev)&&!reads&&of_gets==of_puts);
    }
    const unsigned offsets[]={0,1,3,4,5,0xe,0xf};const u32 expected[]={2,4,2,9,2,0x47,0};
    regmap map;bcl_device b{&map};
    for(int i=0;i<7;i++)values[offsets[i]]=expected[i];
    bad_reg=-1;reads=0;assert(!bcl_legacy_uke_revision(&b)&&reads==7);
    for(int i=0;i<7;i++) {
        bad_reg=offsets[i];reads=0;assert(bcl_legacy_uke_revision(&b)==-EIO&&reads==i+1);
        bad_reg=-1;values[offsets[i]]^=1;reads=0;
        assert(bcl_legacy_uke_revision(&b)==-ENODEV&&reads==i+1);values[offsets[i]]^=1;
    }
    printf("PASS: actual BCL Uke resource admission, %d property-read failures and seven revision errors/mismatches; host only\n",total);
}
CPP
"${CXX:-c++}" -std=gnu++20 -O1 -Wall -Wextra -Werror \
    -fsanitize=address,undefined -fno-omit-frame-pointer "$work/check.cpp" -o "$work/check"
"$work/check"
