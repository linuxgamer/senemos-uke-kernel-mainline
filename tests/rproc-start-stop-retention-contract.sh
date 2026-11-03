#!/usr/bin/env bash
# Actual remoteproc boot/partial-start/stop with host-only DMA and ownership ledgers.
set -Eeuo pipefail
source=${1:?Pass prepared remoteproc_core.c}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
ulimit -c 0
cat > "$work/check.cpp" <<'CPP'
#include <algorithm>
#include <cassert>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#define READ_ONCE(v) (v)
#define RPROC_OFFLINE 0
#define RPROC_RUNNING 2
#define RPROC_ATTACHED 3
#define RPROC_CRASHED 4
#define RPROC_DETACHED 5
struct device {};
struct mutex {};
struct firmware { size_t size=16; };
struct resource_table { char bytes[16]; };
struct rproc_subdev;
struct list_head { std::vector<rproc_subdev *> items; };
#define list_for_each_entry(p,h,n) for(size_t list_i=0;list_i<(h)->items.size()&&((p)=(h)->items[list_i],true);list_i++)
#define list_for_each_entry_reverse(p,h,n) for(int list_i=int((h)->items.size())-1;list_i>=0&&((p)=(h)->items[list_i],true);list_i--)
#define list_for_each_entry_continue_reverse(p,h,n) for(int list_i=int(std::find((h)->items.begin(),(h)->items.end(),p)-(h)->items.begin())-1;list_i>=0&&((p)=(h)->items[list_i],true);list_i--)
struct rproc;
struct rproc_subdev {
    int (*start)(rproc_subdev *);void (*stop)(rproc_subdev *,bool);void (*unprepare)(rproc_subdev *);
    int id;bool started=false,prepared=false;unsigned stops=0,unprepares=0;
};
struct rproc_ops { int (*start)(rproc *);int (*stop)(rproc *);int (*prepare_stop)(rproc *); };
struct rproc {
    struct device dev;struct mutex lock;rproc_ops *ops;list_head subdevs;
    const char *name="fixture",*firmware="fixture.mbn";
    int power=0,state=RPROC_OFFLINE,max_notifyid=0,nb_vdev=0;
    unsigned long bootaddr=0;bool deleting=false,subdevs_started=false,boot_cleanup_pending=false;
    rproc_subdev *failed_subdev=nullptr;
    resource_table *cached_table=nullptr,*table_ptr=nullptr;size_t table_sz=sizeof(resource_table);
};
static bool active,driver_power,iommu,prepared,resources,removed_live;
static int fail_subdev,prepare_error,table_error,stop_error,segment_error;
static unsigned cleanup_count,unprepare_count,disable_count,table_frees,starts,prepare_stops,fw_requests;
static resource_table loaded;
static const struct firmware fw;
template<class... T> void dev_err(device *,const char *,T...) {}
template<class... T> void dev_info(device *,const char *,T...) {}
template<class... T> void pr_err(const char *,T...) {}
static int mutex_lock_interruptible(struct mutex *) { return 0; }
static void mutex_unlock(struct mutex *) {}
static int atomic_inc_return(int *p) { return ++*p; }
static bool atomic_dec_and_test(int *p) { return !--*p; }
static void atomic_dec(int *p) { --*p; }
static void atomic_inc(int *p) { ++*p; }
static void kfree(void *p) { if(p)table_frees++;free(p); }
static int request_firmware(const struct firmware **out,const char *,device *) { fw_requests++;*out=&fw;return 0; }
static void release_firmware(const struct firmware *) {}
static int rproc_attach(rproc *) { return -EOPNOTSUPP; }
static int rproc_load_segments(rproc *,const struct firmware *) { return segment_error; }
static resource_table *rproc_find_loaded_rsc_table(rproc *,const struct firmware *) { return &loaded; }
static int rproc_prepare_subdevices(rproc *r) { for(auto *s:r->subdevs.items)s->prepared=true;return 0; }
static int rproc_fw_sanity_check(rproc *,const struct firmware *) { return 0; }
static int rproc_enable_iommu(rproc *) { assert(!iommu);iommu=true;return 0; }
static int rproc_prepare_device(rproc *) { assert(!prepared);prepared=true;return 0; }
static unsigned long rproc_get_boot_addr(rproc *,const struct firmware *) { return 0x1000; }
static int rproc_parse_fw(rproc *r,const struct firmware *) {
    assert(!r->cached_table);r->cached_table=static_cast<resource_table *>(calloc(1,sizeof(resource_table)));
    assert(r->cached_table);r->table_ptr=r->cached_table;return 0;
}
static constexpr int rproc_loading_handlers=0;
static int rproc_handle_resources(rproc *,int) { assert(!resources);resources=true;return 0; }
static int rproc_alloc_registered_carveouts(rproc *) { return 0; }
static void rproc_resource_cleanup(rproc *) { assert(!active&&!driver_power&&resources);resources=false;cleanup_count++; }
static void rproc_unprepare_device(rproc *) { assert(prepared&&!resources&&!active);prepared=false;unprepare_count++; }
static void rproc_disable_iommu(rproc *) { assert(iommu&&!resources&&!active);iommu=false;disable_count++; }
static int rproc_reset_rsc_table_on_stop(rproc *r) { if(table_error)return table_error;r->table_ptr=r->cached_table;return 0; }
static int start(rproc *) { starts++;active=driver_power=true;return 0; }
static int early_stop(rproc *) { prepare_stops++;if(prepare_error)return prepare_error;active=false;return 0; }
static int stop(rproc *) { if(stop_error)return stop_error;active=driver_power=false;return 0; }
static int sub_start(rproc_subdev *s) { assert(s->prepared);if(s->id==fail_subdev)return -EAGAIN;s->started=true;return 0; }
static void sub_stop(rproc_subdev *s,bool) { assert(s->started);removed_live|=active;s->started=false;s->stops++; }
static void sub_unprepare(rproc_subdev *s) { assert(s->prepared&&!s->started);s->prepared=false;s->unprepares++; }
CPP
if grep -q 'rproc_start_subdevices(struct rproc \*rproc, bool retain_on_failure)' "$source"; then
    printf '#define HAVE_RETAIN_API 1\n' >> "$work/check.cpp"
else
    printf '#define HAVE_RETAIN_API 0\n' >> "$work/check.cpp"
fi
extract() {
    awk -v f="$1" '$0 ~ "^(static )?(int|void) " f "\\([^;]*\\)$" {p=1} p{print} p&&/^}/{exit}' "$source" >> "$work/check.cpp"
}
for f in rproc_start_subdevices rproc_stop_subdevices rproc_unprepare_subdevices \
    rproc_stop rproc_start rproc_fw_boot rproc_boot __rproc_shutdown; do extract "$f"; done
cat >> "$work/check.cpp" <<'CPP'
static void reset() {
    assert(!resources&&!prepared&&!iommu&&!driver_power&&!active);
    removed_live=false;fail_subdev=-1;prepare_error=table_error=stop_error=segment_error=0;
    cleanup_count=unprepare_count=disable_count=table_frees=starts=prepare_stops=fw_requests=0;
}
static void link(rproc &r,rproc_subdev (&sub)[3]) {
    for(int i=0;i<3;i++){sub[i]={sub_start,sub_stop,sub_unprepare,i};r.subdevs.items.push_back(&sub[i]);}
}
static void released(rproc &r,rproc_subdev (&sub)[3],int started) {
    assert(!r.boot_cleanup_pending&&!r.failed_subdev&&!r.subdevs_started&&r.power==0&&r.state==RPROC_OFFLINE);
    assert(!r.cached_table&&!r.table_ptr&&!resources&&!prepared&&!iommu&&!active&&!driver_power);
    assert(cleanup_count==1&&unprepare_count==1&&disable_count==1&&table_frees==1&&!removed_live);
    for(int i=0;i<3;i++)assert(!sub[i].started&&!sub[i].prepared&&sub[i].stops==unsigned(i<started)&&sub[i].unprepares==1);
}
int main() {
    for(int boundary : {1,0,2})for(int phase=0;phase<3;phase++) {
        reset();rproc_ops ops{start,stop,early_stop};rproc r;r.ops=&ops;rproc_subdev sub[3];link(r,sub);
        fail_subdev=boundary;
        if(phase==0)prepare_error=-EIO;
        if(phase==1)table_error=-EIO;
        if(phase==2)stop_error=-EIO;
        int ret=rproc_boot(&r);
        if(ret!=-EIO||!r.boot_cleanup_pending||r.power!=1||removed_live||cleanup_count) {
            fprintf(stderr,"Unsafe startup unwind: ret=%d pending=%d power=%d removed_live=%d cleanup=%u\n",ret,r.boot_cleanup_pending,r.power,removed_live,cleanup_count);return 1;
        }
        assert(r.state==RPROC_CRASHED&&r.cached_table&&resources&&prepared&&iommu&&driver_power);
        for(int i=0;i<3;i++)assert(sub[i].stops==unsigned(phase!=0&&i<boundary)&&sub[i].prepared);
        assert(rproc_boot(&r)==-EBUSY&&r.power==1&&fw_requests==1&&starts==1);
        assert(__rproc_shutdown(&r,false)==-EIO&&r.power==1&&resources&&!cleanup_count);
        prepare_error=table_error=stop_error=0;
        assert(!__rproc_shutdown(&r,false));released(r,sub,boundary);
    }
    reset();rproc_ops ops{start,stop,early_stop};rproc r;r.ops=&ops;rproc_subdev sub[3];link(r,sub);
    assert(!rproc_boot(&r)&&r.state==RPROC_RUNNING&&r.power==1);
    assert(!__rproc_shutdown(&r,false));released(r,sub,3);
    reset();rproc legacy;legacy.ops=&ops;link(legacy,sub);ops.prepare_stop=nullptr;
    assert(!rproc_boot(&legacy)&&!prepare_stops);
    // The legacy stop order intentionally remains unchanged.
    assert(!__rproc_shutdown(&legacy,false)&&removed_live);removed_live=false;released(legacy,sub,3);
    reset();rproc clean;ops.prepare_stop=early_stop;clean.ops=&ops;link(clean,sub);fail_subdev=1;
    assert(rproc_boot(&clean)==-EAGAIN&&clean.power==0&&!clean.boot_cleanup_pending);
    released(clean,sub,1);
    reset();rproc attach;attach.ops=&ops;link(attach,sub);rproc_prepare_subdevices(&attach);
    fail_subdev=1;active=true;
#if HAVE_RETAIN_API
    assert(rproc_start_subdevices(&attach,false)==-EAGAIN);
#else
    assert(rproc_start_subdevices(&attach)==-EAGAIN);
#endif
    assert(removed_live&&!attach.failed_subdev&&!attach.subdevs_started);
    active=false;rproc_unprepare_subdevices(&attach);
    reset();rproc load_fail;load_fail.ops=&ops;link(load_fail,sub);segment_error=-EIO;
    assert(rproc_boot(&load_fail)==-EIO&&load_fail.power==0&&!load_fail.boot_cleanup_pending);
    assert(!load_fail.cached_table&&!resources&&!prepared&&!iommu&&cleanup_count==1);
    puts("PASS: actual remoteproc partial startup at every boundary, three stop faults/retries, power/table/DMA retention, restart refusal and legacy path; host only");
}
CPP
"${CXX:-c++}" -std=gnu++20 -O1 -Wall -Wextra -Werror -Wno-unused-parameter \
    -fsanitize=address,undefined -fno-omit-frame-pointer "$work/check.cpp" -o "$work/check"
"$work/check"
