#!/usr/bin/env bash
# Actual native LLCC functions with memory-only perf/MMIO/CPU/PM fault ledgers.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
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
typedef uint64_t u64;
typedef uint32_t u32;
typedef uint8_t u8;
typedef uint32_t __be32;
typedef uint64_t local64_t;
typedef unsigned int raw_spinlock_t;
#define __iomem
#define BIT(n) (1U<<(n))
#define GENMASK(h,l) ((UINT32_MAX>>(31-(h)))&~((1U<<(l))-1))
#define container_of(p,t,m) ((t *)((char *)(p)-offsetof(t,m)))
#define PERF_HES_STOPPED 1
#define PERF_HES_UPTODATE 2
#define PERF_EF_START 1
#define PERF_ATTACH_TASK 1
#define PERF_PMU_CAP_NO_EXCLUDE 0x40
#define perf_invalid_context -1
#define HRTIMER_MODE_REL 0
#define CLOCK_MONOTONIC 0
#define NSEC_PER_MSEC 1000000
#define CPU_PM_ENTER 1
#define CPU_PM_EXIT 2
#define CPU_PM_ENTER_FAILED 3
#define NOTIFY_DONE 0
#define NOTIFY_OK 1
#define IORESOURCE_MEM 0
#define GFP_KERNEL 0
#define THIS_MODULE ((void *)1)
#define ERR_PTR(e) ((void *)(intptr_t)(e))
#define IS_ERR(p) ((uintptr_t)(p)>=(uintptr_t)-4095)
#define PTR_ERR(p) ((int)(intptr_t)(p))
struct device { void *data; };
struct resource { u64 start,end; };
struct platform_device { struct device dev; struct resource *resource; };
struct pmu;
struct perf_event {
    struct pmu *pmu;int cpu,attach_state;
    struct { unsigned int type;u64 config,config1,config2,sample_period;
        bool exclude_user,exclude_kernel,exclude_hv,exclude_idle,exclude_host,exclude_guest,branch; } attr;
    struct { int idx;unsigned int state; } hw;
    local64_t count;
};
struct pmu {
    void *module,*attr_groups;struct device *parent;int task_ctx_nr;unsigned int capabilities,type;
    int (*event_init)(struct perf_event *);int (*add)(struct perf_event *,int);
    void (*del)(struct perf_event *,int),(*start)(struct perf_event *,int),(*stop)(struct perf_event *,int),(*read)(struct perf_event *);
};
enum hrtimer_restart { HRTIMER_NORESTART,HRTIMER_RESTART };
struct hrtimer { enum hrtimer_restart (*fn)(struct hrtimer *);bool armed; };
struct notifier_block { int (*notifier_call)(struct notifier_block *,unsigned long,void *); };
static char registers[0x300];
static u64 cpu_ids[8];
struct device_node { unsigned int cpu; };
static struct device_node nodes[8];
static unsigned int node_refs;
static int address_cells=1,reg_bytes=4,missing_cpu=-1;
static unsigned int cpus=8,current_cpu,lock_depth,writes,clears,timer_starts,timer_cancels,notifier_regs,notifier_unregs,perf_regs,perf_unregs;
static unsigned int notifier_live,perf_live;
static int map_error,notifier_error,perf_error;
static bool alloc_error;
static void *allocation;
static struct pmu *registered;
static void *llcc_groups;
static unsigned int num_possible_cpus(void) { return cpus; }
#define for_each_possible_cpu(cpu) for((cpu)=0;(cpu)<cpus;(cpu)++)
static struct device_node *of_get_cpu_node(unsigned int cpu,void *thread) { assert(cpu<8&&!thread);if((int)cpu==missing_cpu)return NULL;nodes[cpu].cpu=cpu;node_refs++;return &nodes[cpu]; }
static int of_n_addr_cells(struct device_node *n) { assert(n&&node_refs);return address_cells; }
static const __be32 *of_get_property(struct device_node *n,const char *key,int *bytes) { static __be32 cells[2];assert(n&&node_refs&&!strcmp(key,"reg"));*bytes=reg_bytes;cells[0]=address_cells==2?cpu_ids[n->cpu]>>32:cpu_ids[n->cpu];cells[1]=cpu_ids[n->cpu];return cells; }
static u64 of_read_number(const __be32 *reg,int cells) { assert(node_refs&&cells>=1&&cells<=2);return cells==1?reg[0]:((u64)reg[0]<<32)|reg[1]; }
static void of_node_put(struct device_node *node) { assert(node&&node_refs);node_refs--; }
static bool cpu_possible(unsigned int cpu) { return cpu<cpus; }
static unsigned int smp_processor_id(void) { return current_cpu; }
static void lock(raw_spinlock_t *l) { assert(!lock_depth&&!*l);lock_depth=1;*l=1; }
static void unlock(raw_spinlock_t *l) { assert(lock_depth&&*l);lock_depth=0;*l=0; }
#define raw_spin_lock_irqsave(l,f) do { (f)=0;lock(l); } while(0)
#define raw_spin_unlock_irqrestore(l,f) do { (void)(f);unlock(l); } while(0)
static void raw_spin_lock_init(raw_spinlock_t *l) { *l=0; }
static u32 readl(const void *ptr) { assert((const char *)ptr>=registers&&(const char *)ptr+4<=registers+sizeof(registers));u32 value;memcpy(&value,ptr,4);return value; }
static void reg(unsigned int offset,u32 value) { assert(offset+4<=sizeof(registers));memcpy(registers+offset,&value,4); }
static void writel(u32 value,void *ptr) {
    assert(lock_depth&&ptr==registers+0x200);u32 old=readl(ptr);writes++;
    for(unsigned int bank=0;bank<8;bank++) if((value&BIT(16+bank))&&!(old&BIT(16+bank))) { reg(0x220+4*bank,0);clears++; }
    memcpy(ptr,&value,4);
}
static void local64_add(u64 value,local64_t *count) { assert(lock_depth);*count+=value; }
static bool has_branch_stack(struct perf_event *e) { return e->attr.branch; }
static bool is_sampling_event(struct perf_event *e) { return e->attr.sample_period; }
static u64 ns_to_ktime(u64 ns) { return ns; }
static void hrtimer_setup(struct hrtimer *t,enum hrtimer_restart (*fn)(struct hrtimer *),int clock,int mode) { (void)clock;(void)mode;t->fn=fn; }
static void hrtimer_start(struct hrtimer *t,u64 ns,int mode) { assert(lock_depth&&ns==1000000&&!mode);timer_starts++;t->armed=true; }
static void hrtimer_forward_now(struct hrtimer *t,u64 ns) { assert(lock_depth&&t->fn&&ns==1000000); }
static void hrtimer_cancel(struct hrtimer *t) { assert(!lock_depth);t->armed=false;timer_cancels++; }
static void *devm_kzalloc(struct device *d,size_t size,int flags) { (void)d;(void)flags;assert(!allocation);return alloc_error?NULL:(allocation=calloc(1,size)); }
static struct resource *platform_get_resource(struct platform_device *p,int type,int index) { assert(!type&&!index);return p->resource; }
static u64 resource_size(struct resource *r) { return r->end-r->start+1; }
static void *devm_ioremap_resource(struct device *d,struct resource *r) { (void)d;assert(r);return map_error?ERR_PTR(map_error):registers; }
static int dev_err_probe(struct device *d,int ret,const char *text) { (void)d;assert(text);return ret; }
static void platform_set_drvdata(struct platform_device *p,void *data) { assert(!p->dev.data);p->dev.data=data; }
static void *platform_get_drvdata(struct platform_device *p) { assert(p->dev.data);return p->dev.data; }
static void *dev_get_drvdata(struct device *d) { assert(d->data);return d->data; }
static int cpu_pm_register_notifier(struct notifier_block *nb) { assert(nb->notifier_call&&!notifier_live);notifier_regs++;if(notifier_error)return notifier_error;notifier_live=1;return 0; }
static void cpu_pm_unregister_notifier(struct notifier_block *nb) { assert(nb->notifier_call&&notifier_live);notifier_live=0;notifier_unregs++; }
static int perf_pmu_register(struct pmu *p,const char *name,int type) { assert(!strcmp(name,"sm7675_llcc")&&type==-1&&notifier_live&&!perf_live);perf_regs++;if(perf_error)return perf_error;registered=p;p->type=77;perf_live=1;return 0; }
static int perf_pmu_unregister(struct pmu *p);
C
awk '/^#define LLCC_CPUS/ {emit=1} /^static ssize_t llcc_event_show/ {emit=0} emit {print}' "$root/src/performance/qcom-sm7675-llcc-pmu.c" >> "$work/check.c"
awk '/^static int llcc_probe\(/ {emit=1} /^static DEFINE_SIMPLE/ {emit=0} emit {print}' "$root/src/performance/qcom-sm7675-llcc-pmu.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static int perf_pmu_unregister(struct pmu *pmu) {
    struct sm7675_llcc_pmu *p=to_llcc(pmu);assert(perf_live&&p->removing&&!lock_depth);
    for(unsigned int cpu=0;cpu<8;cpu++)if(p->events[cpu])llcc_del(p->events[cpu],0);
    assert(!p->active);perf_live=0;perf_unregs++;return 0;
}
static void reset(void) {
    assert(!notifier_live&&!perf_live&&!lock_depth&&!node_refs);free(allocation);allocation=NULL;registered=NULL;
    memset(registers,0,sizeof(registers));for(unsigned int i=0;i<8;i++)cpu_ids[i]=i*0x100;
    cpus=8;current_cpu=0;writes=clears=timer_starts=timer_cancels=notifier_regs=notifier_unregs=perf_regs=perf_unregs=0;
    map_error=notifier_error=perf_error=0;alloc_error=false;
    address_cells=1;reg_bytes=4;missing_cpu=-1;
}
static struct resource resource={0x24095000,0x240952ff};
static struct platform_device device(void) { return (struct platform_device){.resource=&resource}; }
static struct perf_event event(struct sm7675_llcc_pmu *p,int cpu) { struct perf_event e={.pmu=&p->pmu,.cpu=cpu,.hw={.idx=-1}};e.attr.type=p->pmu.type;e.attr.config=0x1000;return e; }
static void tick(struct sm7675_llcc_pmu *p,bool expected) { assert(p->timer.fn(&p->timer)==(expected?HRTIMER_RESTART:HRTIMER_NORESTART)); }
int main(void) {
    for(unsigned int fault=0;fault<13;fault++) {
        reset();struct platform_device dev=device();int expected=-EINVAL;
        switch(fault) {
        case 0:dev.resource=NULL;break;
        case 1:alloc_error=true;expected=-ENOMEM;break;
        case 2:cpus=7;break;
        case 3:cpu_ids[7]=0x600;break;
        case 4:cpu_ids[7]=0x800;break;
        case 5:cpu_ids[7]=0x701;break;
        case 6:map_error=-EBUSY;expected=-EBUSY;break;
        case 7:reg(0x200,1);expected=-EBUSY;break;
        case 8:notifier_error=-EAGAIN;expected=-EAGAIN;break;
        case 9:perf_error=-EIO;expected=-EIO;break;
        case 10:missing_cpu=7;break;
        case 11:address_cells=3;break;
        case 12:reg_bytes=8;break;
        }assert(llcc_probe(&dev)==expected&&!dev.dev.data&&!perf_live&&!notifier_live&&!writes);
        assert(notifier_unregs==(fault==9));
    }
    reset();struct platform_device dev=device();assert(!llcc_probe(&dev));struct sm7675_llcc_pmu *p=dev.dev.data;
    assert(!writes&&!timer_starts&&perf_live&&notifier_live&&registered==&p->pmu&&p->pmu.module==THIS_MODULE);
    for(unsigned int i=0;i<8;i++)assert(p->bank[i]==i);
    for(unsigned int fault=0;fault<12;fault++) {
        struct perf_event e=event(p,0);int expected=-EINVAL;
        switch(fault) {
        case 0:e.attr.type++;expected=-ENOENT;break;
        case 1:e.cpu=-1;break;
        case 2:e.cpu=8;break;
        case 3:e.attach_state=PERF_ATTACH_TASK;break;
        case 4:e.attr.config++;break;
        case 5:e.attr.config1=1;break;
        case 6:e.attr.config2=1;break;
        case 7:e.attr.branch=true;break;
        case 8:e.attr.sample_period=1;expected=-EOPNOTSUPP;break;
        case 9:e.attr.exclude_user=true;expected=-EOPNOTSUPP;break;
        case 10:e.attr.exclude_kernel=true;expected=-EOPNOTSUPP;break;
        case 11:e.attr.exclude_guest=true;expected=-EOPNOTSUPP;break;
        }assert(llcc_event_init(&e)==expected&&!writes);
    }
    struct perf_event a=event(p,0),b=event(p,1),collision=event(p,0);
    assert(!llcc_event_init(&a)&&!llcc_event_init(&b));assert(!llcc_add(&a,0)&&!writes&&!p->active);
    assert(llcc_add(&collision,0)==-EAGAIN&&!writes);llcc_start(&a,0);assert(p->active==1&&timer_starts==1&&(readl(registers+0x200)&1));
    assert(!llcc_add(&b,PERF_EF_START)&&p->active==2&&timer_starts==1);
    reg(0x220,10);reg(0x224,20);llcc_read(&a);assert(a.count==80&&b.count==0&&readl(registers+0x224)==20);
    reg(0x220,0xffffffff);tick(p,true);assert(a.count==80+((u64)0xffffff<<3)&&b.count==160);
    tick(p,true);assert(a.count==80+((u64)0xffffff<<3)&&b.count==160);
    reg(0x220,4);llcc_stop(&a,0);assert(a.count==112+((u64)0xffffff<<3)&&p->active==1&&!(readl(registers+0x200)&1));
    unsigned int before=writes;llcc_stop(&a,0);llcc_read(&a);assert(writes==before);
    llcc_start(&a,0);current_cpu=0;reg(0x220,3);assert(llcc_cpu_pm(&p->cpu_pm,CPU_PM_ENTER,NULL)==NOTIFY_OK);assert(a.count==136+((u64)0xffffff<<3)&&!(readl(registers+0x200)&1));
    before=writes;llcc_read(&a);assert(writes==before);llcc_cpu_pm(&p->cpu_pm,CPU_PM_ENTER_FAILED,NULL);assert(readl(registers+0x200)&1);
    reg(0x220,1);reg(0x224,2);assert(!llcc_suspend(&dev.dev)&&p->suspended&&timer_cancels==1);
    before=writes;tick(p,false);llcc_read(&a);assert(writes==before);
    llcc_stop(&a,0);assert(p->active==1);assert(!llcc_resume(&dev.dev)&&!p->suspended&&!(readl(registers+0x200)&1)&&(readl(registers+0x200)&2));
    llcc_del(&a,0);assert(!p->events[0]&&a.hw.idx==-1&&p->active==1);
    reg(0x224,1);llcc_del(&b,0);assert(!p->active&&b.hw.idx==-1);tick(p,false);assert(!(readl(registers+0x200)&255));
    a=event(p,7);assert(!llcc_add(&a,PERF_EF_START));reg(0x23c,9);llcc_remove(&dev);assert(!perf_live&&!notifier_live&&perf_unregs==1&&notifier_unregs==1&&!p->active&&a.count==72&&!p->timer.armed);
    reset();dev=device();address_cells=2;reg_bytes=8;for(unsigned int i=0;i<8;i++)cpu_ids[i]=(7-i)*0x100;
    assert(!llcc_probe(&dev));p=dev.dev.data;for(unsigned int i=0;i<8;i++)assert(p->bank[i]==7-i);llcc_remove(&dev);reset();
    puts("Actual LLCC perf: 13 probe faults, one/two-cell CPU bijection and references, event refusals, exclusive banks, scaled/polled counts, stop/restart, idle, sleep and active-event removal pass; host only");
}
C
"${CC:-clang}" -std=gnu11 -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter \
    -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check"
