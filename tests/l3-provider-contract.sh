#!/usr/bin/env bash
# Actual native L3 probe/set/remove with host-only clock, LUT and graph faults.
set -Eeuo pipefail
kernel=${1:?Pass prepared kernel source}
mode=${2:-all}
case $mode in all|link|clocks|lut|descending|wide|boot-floor) ;; *) exit 2;; esac
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uint32_t u32;
typedef uint16_t u16;
typedef uint64_t u64;
#define EPROBE_DEFER 517
#define GENMASK(h,l) ((UINT32_MAX>>(31-(h)))&~((1U<<(l))-1))
#define FIELD_GET(m,v) (((v)&(m))>>__builtin_ctz(m))
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define container_of(p,t,m) ((t *)((char *)(p)-offsetof(t,m)))
#define struct_size(p,m,n) (sizeof(*(p))+sizeof((p)->m[0])*(n))
#define ERR_PTR(e) ((void *)(intptr_t)(e))
#define IS_ERR(p) ((uintptr_t)(p)>=(uintptr_t)-4095)
#define PTR_ERR(p) ((int)(intptr_t)(p))
#define GFP_KERNEL 0
#define U32_MAX UINT32_MAX
#define check_mul_overflow(a,b,p) __builtin_mul_overflow(a,b,p)
#define __iomem
#define icc_units_to_bps(v) ((u64)(v)*1000)
#define do_div(n,d) ((n)/=(d))
#define dev_err(d,...) ((void)(d),errors++)
#define dev_dbg(d,...) ((void)(d))
#define icc_std_aggregate NULL
#define of_icc_xlate_onecell NULL
struct device { const void *match; };
struct platform_device { struct device dev; void *data; };
struct icc_node;
struct icc_provider {
    struct device *dev; void *data,*aggregate,*xlate;
    int (*set)(struct icc_node *,struct icc_node *);
    int (*get_bw)(struct icc_node *,u32 *,u32 *);
    struct icc_node *nodes[2]; unsigned int count;
};
struct icc_node { unsigned int id,peak_bw,init_avg,init_peak; void *data; struct icc_provider *provider; };
struct icc_onecell_data { size_t num_nodes; struct icc_node *nodes[]; };
struct clk { unsigned long rate; };
static struct clk clocks[2];
static struct icc_node *nodes[2];
static void *allocations[2];
static unsigned char registers[0x2000];
static unsigned int clock_gets,clock_puts,maps,allocs,creates,destroys,removes,registrations,deregistrations,errors,writes;
static unsigned int written_offset,written_value;
static int clock_error=-1,alloc_error=-1,node_error=-1,name_error=-1,link_error,register_error,map_error;
static bool boot_floor;
static unsigned int initial_errors;
static struct clk *clk_get(struct device *dev,const char *name) {
    (void)dev; unsigned int i=!strcmp(name,"alternate"); clock_gets++;
    assert(i||!strcmp(name,"xo")); return (int)i==clock_error?ERR_PTR(-EPROBE_DEFER):clocks+i;
}
static unsigned long clk_get_rate(struct clk *clk) { assert(clk==clocks||clk==clocks+1); return clk->rate; }
static void clk_put(struct clk *clk) { assert(clk==clocks||clk==clocks+1); clock_puts++; }
static void *devm_kzalloc(struct device *dev,size_t size,int flags) {
    (void)dev; (void)flags; unsigned int i=allocs++; assert(i<2);
    return (int)i==alloc_error?NULL:(allocations[i]=calloc(1,size));
}
static void *devm_platform_ioremap_resource(struct platform_device *dev,unsigned int index) {
    (void)dev; assert(!index); maps++; return map_error?ERR_PTR(map_error):registers;
}
static u32 readl_relaxed(const void *p) { assert((const unsigned char *)p>=registers&&(const unsigned char *)p+4<=registers+sizeof(registers)); u32 v; memcpy(&v,p,4); return v; }
static void writel_relaxed(u32 value,void *p) {
    assert((unsigned char *)p>=registers&&(unsigned char *)p+4<=registers+sizeof(registers));
    writes++; written_offset=(unsigned char *)p-registers; written_value=value; memcpy(p,&value,4);
}
static const void *device_get_match_data(struct device *dev) { return dev->match; }
static void icc_provider_init(struct icc_provider *p) { assert(p->dev); }
static struct icc_node *icc_node_create_dyn(void) {
    unsigned int i=creates++; assert(i<2); if((int)i==node_error) return ERR_PTR(-ENOMEM);
    nodes[i]=calloc(1,sizeof(*nodes[i])); assert(nodes[i]); nodes[i]->id=i; return nodes[i];
}
static void icc_node_destroy(unsigned int id) { assert(id<2&&nodes[id]); free(nodes[id]); nodes[id]=NULL; destroys++; }
static int icc_node_set_name(struct icc_node *node,struct icc_provider *p,const char *name) { (void)p; assert(name&&*name); return (int)node->id==name_error?-ENOMEM:0; }
static void icc_node_add(struct icc_node *node,struct icc_provider *p) {
    assert(p->count<2); node->provider=p; p->nodes[p->count++]=node;
    if(boot_floor) {
        if(p->get_bw) assert(!p->get_bw(node,&node->init_avg,&node->init_peak));
        else node->init_avg=node->init_peak=INT32_MAX;
        node->peak_bw=node->init_peak;
        if((node->init_avg||node->init_peak)&&p->set(node,node)) initial_errors++;
        node->peak_bw=0;
    }
}
static int icc_link_nodes(struct icc_node *src,struct icc_node **dst) { assert(src&&dst&&*dst&&src->provider==(*dst)->provider); return link_error; }
static void icc_nodes_remove(struct icc_provider *p) { removes++; while(p->count) icc_node_destroy(p->nodes[--p->count]->id); }
static int icc_provider_register(struct icc_provider *p) { assert(p->count==2); registrations++; return register_error; }
static void icc_provider_deregister(struct icc_provider *p) { assert(p->count==2); deregistrations++; }
static void platform_set_drvdata(struct platform_device *p,void *data) { assert(!p->data); p->data=data; }
static void *platform_get_drvdata(struct platform_device *p) { assert(p->data); return p->data; }
C
cat "$kernel/include/dt-bindings/interconnect/qcom,osm-l3.h" >> "$work/check.c"
awk '/^#define LUT_MAX_ENTRIES/ {emit=1} /^static const struct of_device_id / {emit=0} emit {print}' \
    "$kernel/drivers/interconnect/qcom/osm-l3.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static void finish(void) {
    assert(!nodes[0]&&!nodes[1]);
    for(unsigned int i=0;i<2;i++) { free(allocations[i]); allocations[i]=NULL; }
}
static void reg(unsigned int offset,u32 value) { assert(offset+4<=sizeof(registers)); memcpy(registers+offset,&value,4); }
static void reset(const struct qcom_osm_l3_desc *desc) {
    memset(registers,0,sizeof(registers)); reg(REG_ENABLE,1);
    clocks[0].rate=19200000; clocks[1].rate=600000000;
    clock_gets=clock_puts=maps=allocs=creates=destroys=removes=registrations=deregistrations=errors=writes=0;
    boot_floor=false;initial_errors=0;
    clock_error=alloc_error=node_error=name_error=-1; link_error=register_error=map_error=0;
    for(unsigned int i=0;i<4;i++) reg(desc->reg_freq_lut+i*desc->lut_row_size,(1U<<30)|((unsigned int[]){16,24,32,32})[i]);
}
static struct platform_device device(const struct qcom_osm_l3_desc *desc) { return (struct platform_device){.dev={.match=desc}}; }
static void refused(struct platform_device *p,int expected) { int ret=qcom_osm_l3_probe(p); if(ret!=expected) fprintf(stderr,"probe returned %d, expected %d\n",ret,expected); assert(ret==expected&&!p->data&&!writes&&!nodes[0]&&!nodes[1]); finish(); }
static void accepted(struct platform_device *p,unsigned int count,unsigned long first,unsigned long last) {
    assert(!qcom_osm_l3_probe(p)&&p->data&&registrations==1&&!removes&&!writes);
    struct qcom_osm_l3_icc_provider *qp=p->data;
    assert(qp->max_state==count&&qp->lut_tables[0]==first&&qp->lut_tables[count-1]==last);
    const struct qcom_osm_l3_node *src=nodes[0]->data;
    assert(qp->provider.set==qcom_osm_l3_set);
    nodes[1]->peak_bw=0; assert(!qcom_osm_l3_set(nodes[0],nodes[1])&&written_value==0);
    nodes[1]->peak_bw=first*src->buswidth/1000;
    assert(!qcom_osm_l3_set(nodes[0],nodes[1])&&written_value==0);
    nodes[1]->peak_bw++;
    if(qp->reject_overvote&&count==1) assert(qcom_osm_l3_set(nodes[0],nodes[1])==-ERANGE);
    else assert(!qcom_osm_l3_set(nodes[0],nodes[1])&&written_value==(count==1?0:1));
    nodes[1]->peak_bw=UINT32_MAX;
    if(qp->reject_overvote) {
        unsigned int before=writes;
        assert(qcom_osm_l3_set(nodes[0],nodes[1])==-ERANGE&&writes==before);
        nodes[1]->peak_bw=last*src->buswidth/1000;
        assert(!qcom_osm_l3_set(nodes[0],nodes[1])&&written_value==count-1);
        nodes[1]->peak_bw++;before=writes;
        assert(qcom_osm_l3_set(nodes[0],nodes[1])==-ERANGE&&writes==before);
    } else assert(!qcom_osm_l3_set(nodes[0],nodes[1])&&written_value==count-1&&written_offset==qp->reg_perf_state);
    qcom_osm_l3_remove(p); assert(deregistrations==1&&destroys==2&&removes==1); finish();
}
int main(int argc,char **argv) {
    assert(argc==2); bool all=!strcmp(argv[1],"all");
    const struct qcom_osm_l3_desc *desc=&epss_l3_l3_vote;
    assert(desc->reg_perf_state==0x90&&desc->lut_row_size==4&&desc->reg_freq_lut==0x100&&desc->lut_max_entries==40);
    if(all||!strcmp(argv[1],"link")) {
        reset(desc); struct platform_device p=device(desc); link_error=-ENOMEM;
        refused(&p,-ENOMEM); assert(!registrations&&removes==1&&destroys==2);
    }
    if(all||!strcmp(argv[1],"clocks")) for(unsigned int i=0;i<2;i++) {
        reset(desc); struct platform_device p=device(desc); clocks[i].rate=0;
        refused(&p,-EINVAL); assert(clock_gets==2&&clock_puts==2&&!maps&&!creates);
    }
    if(all||!strcmp(argv[1],"lut")||!strcmp(argv[1],"descending")) for(unsigned int i=!strcmp(argv[1],"descending");i<2;i++) {
        reset(desc); struct platform_device p=device(desc);
        reg(desc->reg_freq_lut+(i?4:0),(1U<<30)|(i?12:0));
        refused(&p,-EINVAL); assert(!creates&&!registrations);
    }
    if(all||!strcmp(argv[1],"wide")) {
        reset(desc); struct platform_device p=device(desc);
        for(unsigned int i=0;i<4;i++) reg(desc->reg_freq_lut+i*4,(1U<<30)|((unsigned int[]){16,240,255,255})[i]);
        accepted(&p,3,307200000UL,4896000000UL);
    }
    if(all||!strcmp(argv[1],"boot-floor")) {
        for(unsigned int bad=0;bad<2;bad++) {
            desc=&sm7675_epss_l3;reset(desc);struct platform_device p=device(desc);
            clocks[0].rate=bad?200000000000000000UL:200000000000UL;
            refused(&p,-ERANGE);assert(!creates&&!registrations);
        }
        desc=&sm7675_epss_l3;reset(desc);boot_floor=true;struct platform_device p=device(desc);
        assert(!qcom_osm_l3_probe(&p));
        if(initial_errors)fprintf(stderr,"Actual native ICC initialization rejected %u default boot floors\n",initial_errors);
        assert(!initial_errors);
        struct qcom_osm_l3_icc_provider *qp=p.data;
        assert(qp->provider.get_bw&&writes==2&&written_value==2);
        for(unsigned int i=0;i<2;i++)assert(!nodes[i]->init_avg&&nodes[i]->init_peak==19660800);
        nodes[1]->peak_bw=nodes[1]->init_peak;assert(!qcom_osm_l3_set(nodes[0],nodes[1]));
        nodes[1]->peak_bw++;unsigned int before=writes;
        assert(qcom_osm_l3_set(nodes[0],nodes[1])==-ERANGE&&writes==before);
        qcom_osm_l3_remove(&p);finish();
    }
    if(all) {
        const struct qcom_osm_l3_desc *descs[]={&osm_l3,&epss_l3_perf_state,&shikra_epss_l3_perf_state,&epss_l3_l3_vote,&sm7675_epss_l3};
        for(unsigned int i=0;i<ARRAY_SIZE(descs);i++) {
            desc=descs[i]; reset(desc); struct platform_device p=device(desc); accepted(&p,3,307200000,614400000);
            reset(desc); p=device(desc); reg(desc->reg_freq_lut,0); reg(desc->reg_freq_lut+desc->lut_row_size,0); accepted(&p,1,300000000,300000000);
            reset(desc); p=device(desc);
            for(unsigned int n=0;n<desc->lut_max_entries;n++) reg(desc->reg_freq_lut+n*desc->lut_row_size,(1U<<30)|(n+1));
            accepted(&p,desc->lut_max_entries,19200000,19200000UL*desc->lut_max_entries);
        }
        desc=&epss_l3_l3_vote;
        for(int i=0;i<2;i++) {
            reset(desc); struct platform_device p=device(desc); clock_error=i; refused(&p,-EPROBE_DEFER); assert(clock_gets==(unsigned int)i+1&&clock_puts==(unsigned int)i&&!maps);
            reset(desc); p=device(desc); alloc_error=i; refused(&p,-ENOMEM); assert(!registrations);
            reset(desc); p=device(desc); node_error=i; refused(&p,-ENOMEM); assert(!registrations&&destroys==(unsigned int)i);
            reset(desc); p=device(desc); name_error=i; refused(&p,-ENOMEM); assert(!registrations&&destroys==(unsigned int)i+1);
        }
        reset(desc); struct platform_device p=device(desc); map_error=-EBUSY; refused(&p,-EBUSY);
        reset(desc); p=device(desc); reg(REG_ENABLE,0); refused(&p,-ENODEV);
        reset(desc); p=device(desc); p.dev.match=NULL; refused(&p,-EINVAL);
        reset(desc); p=device(desc); register_error=-EIO; refused(&p,-EIO); assert(registrations==1&&removes==1&&destroys==2);
    }
    printf("Actual L3 %s: clocks/LUT/graph admission, native vote indices and ownership checked; host only\n",argv[1]);
}
C
"${CC:-clang}" -std=gnu11 -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter \
    -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
    "$work/check.c" -o "$work/check"
"$work/check" "$mode"
