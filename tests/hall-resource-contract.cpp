// SPDX-License-Identifier: GPL-2.0-only
#include <libfdt.h>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <vector>
extern "C" int uke_hall_test(void *);
using Blob=std::vector<unsigned char>;
static int add(void *f,int parent,const char *name) {
    int n=fdt_add_subnode(f,parent,name); assert(n>=0); return n;
}
static Blob fixture() {
    Blob b(32768); auto f=b.data(); assert(!fdt_create_empty_tree(f,b.size()));
    int soc=add(f,0,"soc"), smp=add(f,soc,"qcom,smp2p-adsp");
    int n=add(f,smp,"qcom,hall-in-lid");
    assert(!fdt_setprop_u32(f,n,"phandle",10));
    assert(!fdt_setprop_u32(f,n,"#interrupt-cells",2));
    assert(!fdt_setprop_string(f,n,"qcom,entry-name","mi_hall_lid"));
    smp=fdt_path_offset(f,"/soc/qcom,smp2p-adsp");
    n=add(f,smp,"qcom,hall-in-table");
    assert(!fdt_setprop_u32(f,n,"phandle",11));
    assert(!fdt_setprop_u32(f,n,"#interrupt-cells",2));
    assert(!fdt_setprop_string(f,n,"qcom,entry-name","mi_hall_table"));
    n=add(f,fdt_path_offset(f,"/soc"),"xiaomi_hall");
    assert(!fdt_setprop_string(f,n,"compatible","xiaomi-hall"));
    for(unsigned i=0;i<2;i++) {
        n=add(f,fdt_path_offset(f,"/soc/xiaomi_hall"),i ? "table_hall" : "lid_hall");
        assert(!fdt_setprop_u32(f,n,"linux,code",i));
        assert(!fdt_setprop_u32(f,n,"linux,input-type",5));
        fdt32_t irq[]={cpu_to_fdt32(10+i),0,0,cpu_to_fdt32(10+i),cpu_to_fdt32(1),0};
        assert(!fdt_setprop(f,n,"interrupts-extended",irq,sizeof(irq)));
    }
    return b;
}
static void check(void *f) {
    int parent=fdt_path_offset(f,"/soc/xiaomi_hall"), bytes;
    assert(!std::strcmp(static_cast<const char *>(fdt_getprop(f,parent,"status",nullptr)),"disabled"));
    for(unsigned i=0;i<2;i++) {
        int n=fdt_path_offset(f,i ? "/hall-tablet-mode" : "/hall-lid");
        assert(n>=0 && !fdt_node_check_compatible(f,n,"qcom,smp2p-switch"));
        auto irq=static_cast<const fdt32_t *>(fdt_getprop(f,n,"interrupts-extended",&bytes));
        assert(irq && bytes==24 && irq[0]==irq[3]);
        assert(fdt32_to_cpu(irq[1])==0 && fdt32_to_cpu(irq[4])==1);
        assert(fdt32_to_cpu(irq[2])==1 && fdt32_to_cpu(irq[5])==1);
        auto code=static_cast<const fdt32_t *>(fdt_getprop(f,n,"linux,code",&bytes));
        assert(code && bytes==4 && fdt32_to_cpu(*code)==i);
        assert(!fdt_getprop(f,n,"gpios",nullptr));
        assert(!fdt_getprop(f,n,"hall_pin",nullptr));
        assert(bool(fdt_getprop(f,n,"wakeup-source",nullptr)) == !i);
    }
    assert(fdt_getprop(f,fdt_path_offset(f,"/soc/qcom,smp2p-adsp"),"qcom,selective-wakeup",nullptr));
}
int main(int argc,char **argv) {
    auto base=fixture(), b=base;
    assert(!uke_hall_test(b.data())); check(b.data());
    for(unsigned bad=0;bad<4;bad++) {
        b=base; auto f=b.data();
        int n=fdt_path_offset(f,"/soc/xiaomi_hall/lid_hall");
        if(bad==0) assert(!fdt_setprop_u32(f,n,"linux,code",1));
        if(bad==1) assert(!fdt_setprop_u32(f,n,"linux,input-type",1));
        if(bad==2) assert(!fdt_setprop_u32(f,n,"interrupts-extended",10));
        if(bad==3) {
            n=fdt_path_offset(f,"/soc/qcom,smp2p-adsp/qcom,hall-in-lid");
            assert(!fdt_setprop_u32(f,n,"#interrupt-cells",3));
        }
        assert(uke_hall_test(f)<0);
    }
    if(argc==2 && argv[1][0]) {
        std::ifstream input(argv[1],std::ios::binary);
        Blob raw{std::istreambuf_iterator<char>(input),{}}; assert(!raw.empty());
        Blob expanded(raw.size()+65536); assert(!fdt_open_into(raw.data(),expanded.data(),expanded.size()));
        assert(!uke_hall_test(expanded.data())); check(expanded.data());
        std::puts("Exact OEM paired hall IRQ graph admitted without physical GPIOs");
    }
}
