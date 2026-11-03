#!/usr/bin/env bash
# COPR only: exercise actual perf/ICC/hotplug/PM functions with failing providers.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint32_t u32;typedef uint64_t u64;
#define UKE_MEMLAT_CPUS 8
#define UKE_MEMLAT_EVENTS 4
#define UKE_MEMLAT_SAMPLE_MS 8
#define PERF_TYPE_RAW 4
#define EIO 5
#define ENOMEM 12
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define hlist_entry(p,t,m) ((t *)((char *)(p)-offsetof(t,m)))
#define IS_ERR(p) ((uintptr_t)(p)>(uintptr_t)-4096)
#define PTR_ERR(p) ((int)(intptr_t)(p))
#define ERR_PTR(e) ((void *)(intptr_t)(e))
#define for_each_online_cpu(id) for((id)=0;(id)<2;(id)++)
#define dev_warn_ratelimited(device,format,...) do { assert(device);printf(format,__VA_ARGS__); } while(0)
static u64 div64_u64(u64 a,u64 b) { assert(b);return a/b; }
C
printf '#include "%s/src/power/uke-memlat-policy.h"\n' "$root" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
#define max(a,b) ((a)>(b)?(a):(b))
#define container_of(p,t,m) ((t *)((char *)(p)-offsetof(t,m)))
#define to_delayed_work(p) container_of(p,struct delayed_work,work)
typedef unsigned long cpumask_t;
#define cpumask_clear(m) (*(m)=0)
#define cpumask_set_cpu(id,m) (*(m)|=1UL<<(id))
#define for_each_cpu_and(id,a,b) for((id)=0;(id)<2;(id)++) if((*(a)&*(b))&(1UL<<(id)))
struct perf_event { bool alive,disabled;unsigned reads; };
struct perf_event_attr { u32 type,size,pinned,disabled;u64 config; };
struct mutex { bool held; };
struct hlist_node { int value; };
struct work_struct { int value; };
struct delayed_work { struct work_struct work; };
struct workqueue_struct { int value; };
struct icc_path { unsigned index; };
struct device { void *data; };
struct uke_memlat_cpu { struct perf_event *event[4];struct uke_memlat_count previous[4];u64 timestamp; };
struct uke_memlat_monitor { struct uke_memlat_row map[12];cpumask_t cpus;unsigned rows,group;bool compute; };
struct uke_memlat {
    struct device *dev;struct mutex lock;struct delayed_work work;
    struct workqueue_struct *queue;struct hlist_node hp_node;
    struct icc_path *path[2];struct uke_memlat_cpu cpu[8];
    struct uke_memlat_monitor monitor[7];unsigned monitors;
    u32 vote[2];u64 samples,rejected,vote_errors;int hp_state;bool suspended;
};
static struct uke_memlat p;
static struct device dev;
static struct icc_path paths[2]={{0},{1}};
static struct workqueue_struct queue;
static struct perf_event events[32];
static unsigned created,released,enabled,disabled,queued,cancelled,destroyed,hp_removed;
static unsigned icc_calls[2],requested[2],fail_mask;
static int fail_create=-1;
static bool cpu_lock;
static unsigned idle_mask;
static u64 clock_ns;
static int idle_cpu(unsigned id) { return !!(idle_mask&(1U<<id)); }
static u64 ktime_get_ns(void) { clock_ns+=8000000;return clock_ns; }
static u64 perf_event_read_value(struct perf_event *e,u64 *enabled_time,u64 *running_time) {
    assert(cpu_lock&&p.lock.held&&e->alive&&!e->disabled);
    e->reads++;*enabled_time=*running_time=100*e->reads;return 1000*e->reads;
}
static void mutex_lock(struct mutex *m) { assert(!m->held);m->held=true; }
static void mutex_unlock(struct mutex *m) { assert(m->held);m->held=false; }
static void cpus_read_lock(void) { assert(!cpu_lock);cpu_lock=true; }
static void cpus_read_unlock(void) { assert(cpu_lock);cpu_lock=false; }
static struct perf_event *perf_event_create_kernel_counter(struct perf_event_attr *a,unsigned cpu,void *task,void *handler,void *context) {
    assert(p.lock.held&&a->type==PERF_TYPE_RAW&&a->pinned&&a->size==sizeof(*a));
    assert(!task&&!handler&&!context&&cpu<8&&created<32);
    if((int)created==fail_create)return ERR_PTR(-ENOMEM);
    static const unsigned codes[]={8,17,55,23};assert(a->config==codes[created%4]);
    struct perf_event *e=&events[created++];e->alive=true;e->disabled=a->disabled;return e;
}
static int perf_event_release_kernel(struct perf_event *e) { assert(p.lock.held&&e->alive);e->alive=false;released++;return 0; }
static void perf_event_disable(struct perf_event *e) { assert(cpu_lock&&p.lock.held&&e->alive);e->disabled=true;disabled++; }
static void perf_event_enable(struct perf_event *e) { assert(cpu_lock&&p.lock.held&&e->alive);e->disabled=false;enabled++; }
static int icc_set_bw(struct icc_path *path,u32 average,u32 peak) {
    assert(!average&&path->index<2);icc_calls[path->index]++;requested[path->index]=peak;
    return fail_mask&(1U<<path->index)?-EIO:0;
}
static unsigned msecs_to_jiffies(unsigned ms) { assert(ms==8);return ms; }
static bool queue_delayed_work(struct workqueue_struct *q,struct delayed_work *w,unsigned delay) {
    assert(q==p.queue&&w==&p.work&&delay==8&&!p.suspended);queued++;return true;
}
static bool cancel_delayed_work_sync(struct delayed_work *w) { assert(w==&p.work&&p.suspended&&!p.lock.held);cancelled++;return true; }
static void *dev_get_drvdata(struct device *d) { return d->data; }
static void destroy_workqueue(struct workqueue_struct *q) { assert(q==p.queue&&hp_removed==2);destroyed++; }
static int uke_memlat_offline(unsigned,struct hlist_node *);
static int cpuhp_state_remove_instance(int state,struct hlist_node *node) {
    assert(state==101&&node==&p.hp_node&&cancelled);hp_removed++;
    for(unsigned i=0;i<2;i++)assert(!uke_memlat_offline(i,node));return 0;
}
static void cpuhp_remove_multi_state(int state) { assert(state==101&&hp_removed==1);hp_removed++; }
C
for function in release_cpu online offline commit sample stop suspend resume; do
    awk -v name="uke_memlat_$function" '
      $0 ~ "^static (int|void) " name "\\(" {emit=1;found++}
      emit {print}
      emit && /^}/ {emit=0}
      END {if(found!=1)exit 1}
    ' "$root/src/power/uke-memlat.c" >> "$work/check.c"
done
cat >> "$work/check.c" <<'C'
static void reset(void) {
    memset(&p,0,sizeof(p));memset(events,0,sizeof(events));
    created=released=enabled=disabled=queued=cancelled=destroyed=hp_removed=0;
    memset(icc_calls,0,sizeof(icc_calls));memset(requested,0,sizeof(requested));
    fail_create=-1;fail_mask=idle_mask=0;clock_ns=0;cpu_lock=false;p.dev=&dev;dev.data=&p;
    p.path[0]=&paths[0];p.path[1]=&paths[1];p.queue=&queue;p.hp_state=101;
}
static void online(void) {
    for(unsigned i=0;i<2;i++){assert(!uke_memlat_online(i,&p.hp_node));p.cpu[i].timestamp=123;}
    assert(created==8&&!released&&!p.rejected);
}
int main(void) {
    for(int fault=0;fault<4;fault++) {
        reset();fail_create=fault;assert(!uke_memlat_online(0,&p.hp_node));
        assert(created==(unsigned)fault&&released==created&&p.rejected==1);
        for(unsigned i=0;i<4;i++)assert(!p.cpu[0].event[i]);
        assert(!p.cpu[0].timestamp&&!p.lock.held);
    }
    reset();p.suspended=true;assert(!uke_memlat_online(0,&p.hp_node));
    for(unsigned i=0;i<4;i++)assert(p.cpu[0].event[i]->disabled);
    assert(!uke_memlat_offline(0,&p.hp_node)&&created==released);
    reset();u32 vote[]={600000,806400};assert(!uke_memlat_commit(&p,vote));
    assert(requested[0]==600000*16&&requested[1]==806400*32);
    assert(!uke_memlat_commit(&p,vote)&&icc_calls[0]==1&&icc_calls[1]==1);
    for(unsigned failed=1;failed<=3;failed++) {
        reset();online();p.vote[0]=600000;p.vote[1]=806400;fail_mask=failed;
        assert(uke_memlat_suspend(&dev)==-EIO);
        assert(!p.suspended&&cancelled==1&&queued==1&&!disabled);
        assert(p.vote[0]==((failed&1)?600000U:0U));
        assert(p.vote[1]==((failed&2)?806400U:0U));
        assert(p.vote_errors==((failed==3)?2U:1U));
        fail_mask=0;assert(!uke_memlat_suspend(&dev));
        assert(p.suspended&&!p.vote[0]&&!p.vote[1]&&disabled==8);
        assert(!uke_memlat_resume(&dev));
        assert(!p.suspended&&enabled==8&&queued==2);
        for(unsigned i=0;i<2;i++)assert(!p.cpu[i].timestamp);
        uke_memlat_stop(&p);assert(created==released&&destroyed==1&&hp_removed==2);
    }
    reset();online();assert(!uke_memlat_offline(1,&p.hp_node));assert(released==4);
    assert(!uke_memlat_suspend(&dev)&&disabled==4);assert(!uke_memlat_resume(&dev)&&enabled==4);
    uke_memlat_stop(&p);assert(created==released&&destroyed==1);
    reset();online();idle_mask=3;
    uke_memlat_sample(&p.work.work);assert(p.samples==1&&queued==1);
    for(unsigned i=0;i<8;i++)assert(!events[i].reads);
    assert(!p.cpu[0].timestamp&&!p.cpu[1].timestamp);
    idle_mask=2;uke_memlat_sample(&p.work.work);assert(p.samples==2&&queued==2);
    for(unsigned i=0;i<8;i++)assert(events[i].reads==(i<4?1U:0U));
    assert(p.cpu[0].timestamp&&!p.cpu[1].timestamp);
    p.suspended=true;uke_memlat_sample(&p.work.work);assert(p.samples==2&&queued==2);
    for(unsigned i=0;i<8;i++)assert(events[i].reads==(i<4?1U:0U));
    uke_memlat_stop(&p);assert(created==released&&destroyed==1);
    puts("Actual Uke MEMLAT: every counter allocation fault, non-veto hotplug, disabled hotplug, ICC units/errors, suspend rollback, resume baselines and removal pass; fake providers, host only");
}
C
"${CC:-clang}" -std=c11 -Wall -Wextra -Werror -Wno-unused-function -Wno-misleading-indentation -fsanitize=undefined,address -fno-sanitize-recover=all "$work/check.c" -o "$work/check"
"$work/check"
