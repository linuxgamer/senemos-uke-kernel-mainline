#!/usr/bin/env bash
# Actual OPP bandwidth/transition/allocation functions; host API faults only.
set -Eeuo pipefail
kernel=${1:?Pass prepared kernel}
mode=${2:-all}
case $mode in all|rollback|retry|disable|allocation) ;; *) exit 2;; esac
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
#define EPROBE_DEFER 517
#define IS_ERR(p) ((uintptr_t)(p)>=(uintptr_t)-4095)
#define PTR_ERR(p) ((int)(intptr_t)(p))
#define ERR_PTR(e) ((void *)(intptr_t)(e))
#define unlikely(v) (v)
#define container_of(p,t,m) ((t *)((char *)(p)-offsetof(t,m)))
#define __free(fn) __attribute__((cleanup(cleanup_##fn)))
#define EXPORT_SYMBOL_GPL(n)
#define dev_err(d,...) ((void)(d),errors++)
#define dev_warn(d,...) ((void)(d))
#define dev_dbg(d,...) ((void)(d))
#define dev_dbg_ratelimited(d,...) ((void)(d))
#define WARN_ON(v) assert(!(v))
#define INIT_LIST_HEAD(p) (*(p)=0)
#define BLOCKING_INIT_NOTIFIER_HEAD(p) (*(p)=0)
#define list_for_each_entry_safe(p,t,h,m) for((p)=NULL,(t)=NULL;(p)!=NULL;(p)=(t))
struct device_node { int refs; };
struct device { struct device_node *of_node; };
struct regulator { int unused; };
struct kref { int refs; };
struct dev_pm_opp_icc_bw { u32 avg,peak; };
struct dev_pm_opp { struct dev_pm_opp_icc_bw *bandwidth; unsigned long rates[1]; unsigned int level; int refs; };
struct icc_path { struct dev_pm_opp_icc_bw request; unsigned int index,refs; };
struct opp_table {
    int node,lazy,lock,dev_list,opp_list,head,regulator_count;
    struct kref kref;
    void *clk;
    struct dev_pm_opp *current_opp;
    struct icc_path **paths;
    struct dev_pm_opp_icc_bw *current_bw;
    unsigned int path_count;
    bool enabled,bw_dirty;
    struct regulator **regulators;
    int (*config_clks)(struct device *,struct opp_table *,struct dev_pm_opp *,void *,bool);
    int (*config_regulators)(struct device *,struct dev_pm_opp *,struct dev_pm_opp *,struct regulator **,unsigned int);
};
struct opp_device { int unused; };
static struct icc_path hardware[3];
static struct dev_pm_opp_icc_bw old_bw[3],new_bw[3],cache[3];
static struct dev_pm_opp old_opp,new_opp;
static struct icc_path *handles[]={hardware,hardware+1,hardware+2};
static void *allocations[16];
static unsigned int live,allocs,frees,errors,calls,puts_count,gets_count,node_puts,removed,destroyed,reg_disables;
static int alloc_error=-1,path_error=-1,supported=1,phandles=4,clock_error,level_error,opp_table_lock;
static unsigned int fail_calls[16],call_path[32],fail_count;
static struct device_node dt;
static struct device dev={.of_node=&dt};
static struct opp_device opp_dev;
static void *xalloc(size_t size) {
    unsigned int i=allocs++; assert(i<16); if((int)i==alloc_error) return NULL;
    void *p=calloc(1,size?size:1); assert(p); allocations[i]=p; live++; return p;
}
static void kfree(void *p) {
    if(!p) return;
    for(unsigned int i=0;i<16;i++) if(allocations[i]==p) { allocations[i]=NULL; assert(live); live--; frees++; free(p); return; }
    assert(!"free of an unowned allocation");
}
#define kzalloc_obj(x) xalloc(sizeof(x))
#define kzalloc_objs(x,n) xalloc(sizeof(x)*(n))
static int icc_set_bw(struct icc_path *path,u32 avg,u32 peak) {
    assert(path&&path->index<3&&calls<32); call_path[calls]=path->index; calls++;
    for(unsigned int i=0;i<fail_count;i++) if(fail_calls[i]==calls) return i?-ETIMEDOUT:-EIO;
    path->request=(struct dev_pm_opp_icc_bw){avg,peak}; return 0;
}
static void icc_put(struct icc_path *path) { assert(path&&path->refs); path->refs--; puts_count++; }
static struct icc_path *of_icc_get_by_index(struct device *d,int i) {
    (void)d; assert(i>=0&&i<3); gets_count++;
    if(i==path_error) return ERR_PTR(-EPROBE_DEFER);
    hardware[i].refs++; return hardware+i;
}
static struct device_node *of_node_get(struct device_node *np) { if(np) np->refs++; return np; }
static void cleanup_device_node(struct device_node **np) { if(*np) { assert((*np)->refs); (*np)->refs--; node_puts++; } }
static int of_count_phandle_with_args(struct device_node *np,const char *p,const char *cells) { assert(np&&!strcmp(p,"interconnects")&&!strcmp(cells,"#interconnect-cells")); return phandles; }
static int _bandwidth_supported(struct device *d,struct opp_table *t) { (void)d;(void)t;return supported; }
static int dev_err_probe(struct device *d,int error,const char *format,...) { (void)d;(void)format;errors++;return error; }
static void _find_current_opp(struct device *d,struct opp_table *t) { (void)d; assert(!t->current_opp); t->current_opp=&old_opp; old_opp.refs++; }
static struct dev_pm_opp *dev_pm_opp_get(struct dev_pm_opp *o) { o->refs++; return o; }
static void dev_pm_opp_put(struct dev_pm_opp *o) { assert(o->refs>0);o->refs--; }
static int _get_opp_count(struct opp_table *t) { (void)t;return 2; }
static int _set_opp_level(struct device *d,struct dev_pm_opp *o) { (void)d;(void)o;return level_error; }
static int _set_required_opps(struct device *d,struct opp_table *t,struct dev_pm_opp *o,bool up) { (void)d;(void)t;(void)o;(void)up;return 0; }
static int _opp_compare_key(struct opp_table *t,struct dev_pm_opp *a,struct dev_pm_opp *b) { (void)t;return a->bandwidth[0].peak<b->bandwidth[0].peak?-1:a->bandwidth[0].peak>b->bandwidth[0].peak; }
static int regulator_disable(struct regulator *r) { assert(r);reg_disables++;return 0; }
static int configure_clocks(struct device *d,struct opp_table *t,struct dev_pm_opp *o,void *data,bool down) { (void)d;(void)t;(void)o;(void)data;(void)down;return clock_error; }
static void mutex_init(int *m) { *m=1; }
static void mutex_destroy(int *m) { (void)m;destroyed++; }
static void mutex_unlock(int *m) { (void)m; }
static void list_del(int *n) { (void)n; }
static int list_empty(int *n) { (void)n;return 1; }
static void kref_init(struct kref *r) { r->refs=1; }
static void clk_put(void *clk) { assert(!"unexpected clock ownership");(void)clk; }
static struct opp_device *_add_opp_dev(struct device *d,struct opp_table *t) { (void)d;(void)t;return &opp_dev; }
static void _of_init_opp_table(struct opp_table *t,struct device *d,int i) { (void)t;(void)d;assert(!i); }
static void _of_clear_opp_table(struct opp_table *t) { (void)t; }
static void _remove_opp_dev(struct opp_device *o,struct opp_table *t) { (void)t;assert(o==&opp_dev);removed++; }
C
awk '/^(static int _set_opp_bw\(|static int _disable_opp_table\(|static int _set_opp\()/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$kernel/drivers/opp/core.c" >> "$work/check.c"
awk '/^int dev_pm_opp_of_find_icc_paths\(/ {emit=1} emit {print} emit && /^}/ {exit}' "$kernel/drivers/opp/of.c" >> "$work/check.c"
awk '/^static struct opp_table \*_allocate_opp_table\(/ {emit=1} emit {print} emit && /^}/ {exit}' "$kernel/drivers/opp/core.c" >> "$work/check.c"
awk '/^static void _opp_table_kref_release\(/ {emit=1} emit {print} emit && /^}/ {exit}' "$kernel/drivers/opp/core.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static void reset(bool enabled,unsigned int count) {
    assert(!live&&!dt.refs);
    for(unsigned int i=0;i<3;i++) {
        assert(!hardware[i].refs); old_bw[i]=(struct dev_pm_opp_icc_bw){i+1,100+i*200};
        new_bw[i]=(struct dev_pm_opp_icc_bw){i+2,200+i*200};
        cache[i]=enabled?old_bw[i]:(struct dev_pm_opp_icc_bw){0,0};
        hardware[i]=(struct icc_path){.index=i,.request=cache[i]};
    }
    old_opp=(struct dev_pm_opp){.bandwidth=old_bw,.refs=1};
    new_opp=(struct dev_pm_opp){.bandwidth=new_bw};
    memset(allocations,0,sizeof(allocations)); allocs=frees=errors=calls=puts_count=gets_count=node_puts=removed=destroyed=reg_disables=0;
    alloc_error=path_error=-1; supported=1;phandles=count*2; clock_error=level_error=0;fail_count=0;
}
static struct opp_table table(bool enabled,unsigned int count) { return (struct opp_table){.current_opp=&old_opp,.current_bw=cache,.paths=handles,.path_count=count,.enabled=enabled}; }
static void expect(const struct dev_pm_opp_icc_bw *values,unsigned int n) { for(unsigned int i=0;i<n;i++) assert(!memcmp(&hardware[i].request,values+i,sizeof(*values))); }
static void failure(unsigned int first,unsigned int second) { fail_count=second?2:1;fail_calls[0]=first;fail_calls[1]=second; }
int main(int argc,char **argv) {
    assert(argc==2); bool all=!strcmp(argv[1],"all");
    if(all||!strcmp(argv[1],"rollback")) {
        reset(true,2);struct opp_table t=table(true,2);failure(2,0);
        assert(_set_opp_bw(&t,&new_opp,&dev)==-EIO);expect(old_bw,2);
    }
    if(all||!strcmp(argv[1],"rollback")) for(unsigned int n=1;n<=3;n++) for(unsigned int point=1;point<=n;point++) {
        for(unsigned int enabled=0;enabled<2;enabled++) {
            reset(enabled,n);struct opp_table t=table(enabled,n);failure(point,0);
            assert(_set_opp_bw(&t,&new_opp,&dev)==-EIO);
            expect(cache,n);assert(!t.bw_dirty&&calls==point+n);
            for(unsigned int i=0;i<n;i++) assert(call_path[point+i]==n-1-i);
            assert(t.current_opp==&old_opp&&old_opp.refs==1&&!new_opp.refs);
        }
    }
    if(all||!strcmp(argv[1],"retry")) {
        reset(true,2);struct opp_table t=table(true,2);t.bw_dirty=true;hardware[0].request=new_bw[0];
        assert(!_set_opp(&dev,&t,&old_opp,NULL,false)&&calls==2&&!t.bw_dirty);expect(old_bw,2);
        reset(true,2);t=table(true,2);failure(2,4);
        assert(_set_opp(&dev,&t,&new_opp,NULL,false)==-EIO&&t.bw_dirty&&t.current_opp==&old_opp);
        assert(hardware[0].request.peak==200&&cache[0].peak==100);
        fail_count=0;unsigned int before=calls;
        assert(!_set_opp(&dev,&t,&old_opp,NULL,false)&&!t.bw_dirty&&calls==before+2);
        expect(old_bw,2);assert(old_opp.refs==1&&!new_opp.refs);
        before=calls;assert(!_set_opp(&dev,&t,&old_opp,NULL,false)&&calls==before);
        assert(!_set_opp(&dev,&t,&old_opp,NULL,true)&&calls==before+2);
    }
    if(all||!strcmp(argv[1],"disable")) {
        reset(false,2);struct opp_table t=table(false,2);t.bw_dirty=true;
        struct regulator reg={0},*regs[]={&reg};t.regulators=regs;
        hardware[0].request=new_bw[0];assert(!_disable_opp_table(&dev,&t));
        assert(calls==2&&!t.bw_dirty&&!t.enabled&&!reg_disables);expect(cache,2);
        assert(!cache[0].peak&&!cache[1].peak);
    }
    if(all||!strcmp(argv[1],"allocation")) {
        for(int fail=0;fail<3;fail++) {
            reset(false,2);alloc_error=fail;struct opp_table *t=_allocate_opp_table(&dev,0);
            assert(IS_ERR(t)&&PTR_ERR(t)==-ENOMEM&&!live&&!dt.refs);
            assert(!hardware[0].refs&&!hardware[1].refs);
        }
        reset(false,2);struct opp_table *t=_allocate_opp_table(&dev,0);
        assert(!IS_ERR(t)&&t->current_bw&&allocs==3&&live==3);
        assert(!t->current_bw[0].avg&&!t->current_bw[1].peak);
        _opp_table_kref_release(&t->kref);assert(!live&&frees==3&&puts_count==2&&destroyed==1&&!dt.refs);
        reset(false,2);assert(!dev_pm_opp_of_find_icc_paths(&dev,NULL)&&allocs==1&&!live&&gets_count==2&&puts_count==2&&!dt.refs);
        for(int point=0;point<2;point++) {
            reset(false,2);path_error=point;t=_allocate_opp_table(&dev,0);
            assert(IS_ERR(t)&&PTR_ERR(t)==-EPROBE_DEFER&&!live&&!dt.refs&&puts_count==(unsigned int)point);
        }
        reset(false,2);phandles=3;struct opp_table empty={0};
        assert(dev_pm_opp_of_find_icc_paths(&dev,&empty)==-EINVAL&&!live&&!dt.refs);
    }
    if(all) {
        for(unsigned int n=1;n<=3;n++) for(unsigned int point=1;point<=n;point++) for(unsigned int restore=1;restore<=n;restore++) {
            reset(true,n);struct opp_table t=table(true,n);failure(point,point+restore);
            assert(_set_opp(&dev,&t,&new_opp,NULL,false)==-EIO&&t.bw_dirty&&t.current_opp==&old_opp);
            assert(calls==point+n&&errors>=2&&!memcmp(cache,old_bw,n*sizeof(*cache))&&!allocs);
            fail_count=0;unsigned int before=calls;
            assert(!_set_opp(&dev,&t,&old_opp,NULL,false)&&!t.bw_dirty&&calls==before+n);expect(old_bw,n);
        }
        for(unsigned int n=1;n<=3;n++) {
            reset(true,n);struct opp_table t=table(true,n);
            assert(!_set_opp(&dev,&t,&new_opp,NULL,false)&&t.enabled&&!t.bw_dirty);expect(new_bw,n);
            assert(t.current_opp==&new_opp&&!old_opp.refs&&new_opp.refs==1);assert(!memcmp(cache,new_bw,n*sizeof(*cache)));
            assert(!_set_opp(&dev,&t,&old_opp,NULL,false)&&!t.bw_dirty);expect(old_bw,n);
            assert(!_disable_opp_table(&dev,&t)&&!t.enabled&&!t.bw_dirty);expect(cache,n);assert(!cache[0].peak);
        }
        reset(true,2);struct opp_table t=table(true,2);failure(2,0);
        assert(_disable_opp_table(&dev,&t)==-EIO&&t.enabled&&!t.bw_dirty);expect(old_bw,2);
        fail_count=0;assert(!_disable_opp_table(&dev,&t)&&!t.enabled&&!t.bw_dirty);
        reset(true,2);t=table(true,2);t.config_clks=configure_clocks;clock_error=-EAGAIN;
        assert(_set_opp(&dev,&t,&new_opp,NULL,false)==-EAGAIN&&t.bw_dirty&&t.current_opp==&old_opp);expect(new_bw,2);
        failure(4,0);assert(_set_opp_bw(&t,&old_opp,&dev)==-EIO&&t.bw_dirty);expect(new_bw,2);
        assert(!memcmp(cache,new_bw,2*sizeof(*cache)));
        fail_count=0;
        clock_error=0;assert(!_set_opp(&dev,&t,&old_opp,NULL,false)&&!t.bw_dirty);expect(old_bw,2);
        reset(true,2);t=table(true,2);struct regulator reg={0},*regs[]={&reg};t.regulators=regs;level_error=-EIO;
        assert(_disable_opp_table(&dev,&t)==-EIO&&!t.enabled&&t.bw_dirty&&reg_disables==1);
        level_error=0;assert(!_disable_opp_table(&dev,&t)&&!t.bw_dirty&&reg_disables==1);
        reset(true,2);t=table(true,2);t.paths=NULL;t.path_count=0;t.current_bw=NULL;
        assert(!_set_opp(&dev,&t,&new_opp,NULL,false)&&!calls);
    }
    printf("Actual OPP %s: owned bandwidth snapshot, rollback/retry/disable and path allocation/release checked; host only\n",argv[1]);
}
C
"${CC:-clang}" -std=gnu11 -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter -Wno-sign-compare \
    -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
    "$work/check.c" -o "$work/check"
"$work/check" "$mode"
