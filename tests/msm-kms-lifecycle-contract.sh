#!/usr/bin/env bash
# COPR-only: execute real lifecycle functions with fault injection and gated races.
set -Eeuo pipefail
ulimit -c 0
candidate=${1:?Pass prepared candidate}
baseline=${2:?Pass preceding source}
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
extract() {
    local file=$1 name=$2 optional=${3:-false}
    awk -v name="$name" -v optional="$optional" '
      $0 ~ "^(static )?(inline )?(int|void|enum hrtimer_restart) " name "\\(" && $0 !~ /;[[:space:]]*$/ {emit=1;found=1}
      emit {print} emit && /^}/ {exit}
      END {if(!found && optional!="true")exit 1}' "$file"
}
cat > "$work/preamble.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#define MAX_CRTCS 2
#define ARRAY_SIZE(x) (sizeof(x)/sizeof((x)[0]))
#define ERR_PTR(n) ((void *)(intptr_t)(n))
#define PTR_ERR(p) ((int)(intptr_t)(p))
#define IS_ERR(p) ((uintptr_t)(p)>=(uintptr_t)-4095)
#define IRQ_NOTCONNECTED 0x80000000U
#define BUG_ON(x) assert(!(x))
#define DRM_ERROR(...) ((void)0)
#define DRM_DEV_ERROR(...) ((void)0)
#define container_of(p,t,m) ((t *)((char *)(p)-offsetof(t,m)))
struct mutex { bool alive; };
static void mutex_init(struct mutex *m) { m->alive=true; }
static void mutex_destroy(struct mutex *m) { assert(m->alive);m->alive=false; }
typedef struct {pthread_mutex_t native;} spinlock_t;
static pthread_mutex_t gate=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed=PTHREAD_COND_INITIALIZER;
static bool queue_block,queue_entered,queue_release,callback_entered,callback_release,clear_attempt,clear_done,destroy_attempt;
static spinlock_t *watched_fault,*watched_dump;
static _Thread_local bool clearing,destroying;
static void spin_lock_init(spinlock_t *l) { assert(!pthread_mutex_init(&l->native,NULL)); }
static void lock_spin(spinlock_t *l) {
 if((clearing&&l==watched_fault)||(destroying&&l==watched_dump)) {
  pthread_mutex_lock(&gate);if(clearing)clear_attempt=true;else destroy_attempt=true;
  pthread_cond_broadcast(&changed);pthread_mutex_unlock(&gate);
 }
 assert(!pthread_mutex_lock(&l->native));
}
#define spin_lock_irqsave(l,f) do {(f)=0;lock_spin(l);}while(0)
#define spin_unlock_irqrestore(l,f) do {(void)(f);assert(!pthread_mutex_unlock(&(l)->native));}while(0)
static void await(bool *flag) {
 struct timespec deadline;assert(!clock_gettime(CLOCK_REALTIME,&deadline));deadline.tv_sec+=5;
 while(!*flag)assert(!pthread_cond_timedwait(&changed,&gate,&deadline));
}
struct kthread_work {void (*function)(struct kthread_work *);};
typedef void (*kthread_work_func_t)(struct kthread_work *);
struct kthread_worker {bool alive;int kind,queued;void *task;};
struct hrtimer;
enum hrtimer_restart {HRTIMER_NORESTART};
enum hrtimer_mode {HRTIMER_MODE_ABS};
struct hrtimer {bool initialized,active;enum hrtimer_restart (*function)(struct hrtimer *);};
struct msm_hrtimer_work {struct hrtimer timer;struct kthread_work work;struct kthread_worker *worker;};
struct msm_kms;
struct msm_pending_timer {struct msm_hrtimer_work work;struct kthread_worker *worker;struct msm_kms *kms;unsigned crtc_idx;};
struct device {void *drvdata;};
struct platform_device {struct device dev;};
struct msm_mmu_funcs {int unused;};
enum msm_mmu_type {MSM_MMU_IOMMU};
struct msm_mmu {const struct msm_mmu_funcs *funcs;struct device *dev;spinlock_t handler_lock;int (*handler)(void *,unsigned long,int,void *);void *arg;enum msm_mmu_type type;};
struct msm_iommu {struct msm_mmu base;};
struct iommu_domain {int unused;};
struct vm {struct msm_mmu *mmu;};
struct drm_device;
struct drm_crtc {struct drm_device *dev;unsigned index;struct {int id;} base;};
struct drm_driver {const char *name;};
struct drm_device {struct device *dev;const struct drm_driver *driver;struct msm_drm_private *dev_private;struct {bool normalize_zpos;void *funcs,*helper_private;unsigned num_crtc;} mode_config;struct drm_crtc crtcs[MAX_CRTCS];};
struct msm_drm_thread {struct drm_device *dev;struct kthread_worker *worker;};
struct workqueue_struct {bool alive;};
struct msm_kms_funcs {int (*hw_init)(struct msm_kms *);void (*destroy)(struct msm_kms *);void (*irq_preinstall)(struct msm_kms *);int (*irq_postinstall)(struct msm_kms *);void (*irq_uninstall)(struct msm_kms *);};
struct msm_kms {const struct msm_kms_funcs *funcs;struct drm_device *dev;unsigned irq;bool irq_requested;_Atomic int fault_snapshot_capture;struct vm *vm;spinlock_t dump_lock;struct kthread_worker *dump_worker;struct kthread_work dump_work;struct mutex dump_mutex,commit_lock[MAX_CRTCS];struct msm_pending_timer pending_timers[MAX_CRTCS];struct workqueue_struct *wq;struct msm_drm_thread event_thread[MAX_CRTCS];};
struct msm_drm_private {struct drm_device *dev;struct msm_kms *kms;int (*kms_init)(struct drm_device *);};
#define to_platform_device(d) container_of(d,struct platform_device,dev)
#define platform_get_drvdata(p) ((struct msm_drm_private *)(p)->dev.drvdata)
#define dev_get_drvdata(d) ((struct msm_drm_private *)(d)->drvdata)
#define to_msm_vm(v) (v)
#define drm_for_each_crtc(c,d) for((c)=(d)->crtcs;(c)<(d)->crtcs+(d)->mode_config.num_crtc;(c)++)
static unsigned drm_crtc_index(struct drm_crtc *c) {return c->index;}
static int mode_config_funcs,mode_config_helper_funcs;
static struct kthread_worker workers[32];static unsigned worker_count,worker_calls;static int fail_worker,fail_stage;
static struct workqueue_struct wq;static bool fail_wq,irq_live,hw_live,enforce_order,race_timer;
static unsigned backend_destroys,queued_inflight;
static int atomic_read(_Atomic int *v) {return atomic_load(v);}
static void atomic_inc(_Atomic int *v) {atomic_fetch_add(v,1);}
static struct kthread_worker *kthread_run_worker(unsigned f,const char *fmt,...) {
 (void)f;int call=worker_calls++;if(call==fail_worker)return ERR_PTR(-ENOMEM);
 assert(worker_count<ARRAY_SIZE(workers));struct kthread_worker *w=&workers[worker_count++];
 *w=(struct kthread_worker){.alive=true,.kind=strstr(fmt,"atomic-worker")?1:strstr(fmt,"crtc_event")?2:0};w->task=w;return w;
}
static void sched_set_fifo(void *p) {(void)p;}
static void kthread_init_work(struct kthread_work *w,void (*fn)(struct kthread_work *)) {w->function=fn;}
static void kthread_queue_work(struct kthread_worker *w,struct kthread_work *work) {
 (void)work;assert(w&&!IS_ERR(w)&&w->alive);
 pthread_mutex_lock(&gate);queued_inflight++;
 if(queue_block){queue_entered=true;pthread_cond_broadcast(&changed);await(&queue_release);}
 assert(w->alive);w->queued++;queued_inflight--;pthread_mutex_unlock(&gate);
}
static void kthread_destroy_worker(struct kthread_worker *w) {
 assert(w&&!IS_ERR(w)&&w->alive);
 pthread_mutex_lock(&gate);assert(!queued_inflight);pthread_mutex_unlock(&gate);
 if(w->kind==1&&w->queued&&enforce_order)assert(irq_live&&hw_live);
 w->queued=0;w->alive=false;
}
static void hrtimer_setup(struct hrtimer *t,enum hrtimer_restart (*fn)(struct hrtimer *),clockid_t clock,int mode) {(void)clock;(void)mode;*t=(struct hrtimer){.initialized=true,.function=fn};}
static int hrtimer_cancel(struct hrtimer *t) {
 assert(t->initialized);if(t->active&&race_timer)t->function(t);int active=t->active;t->active=false;return active;
}
static struct workqueue_struct *alloc_ordered_workqueue(const char *name,unsigned f) {(void)name;(void)f;if(fail_wq)return NULL;assert(!wq.alive);wq.alive=true;return &wq;}
static void flush_workqueue(struct workqueue_struct *q) {assert(q&&q->alive);}
static void destroy_workqueue(struct workqueue_struct *q) {assert(q&&q->alive);q->alive=false;}
static void msm_atomic_pending_work(struct kthread_work *w) {(void)w;}
static void _msm_disp_snapshot_work(struct kthread_work *w) {(void)w;}
static int msm_irq(int irq,void *arg) {(void)irq;(void)arg;return 0;}
static int request_irq(unsigned irq,int (*fn)(int,void *),unsigned flags,const char *name,void *dev) {(void)irq;(void)fn;(void)flags;(void)name;(void)dev;if(fail_stage==3)return -EIO;assert(!irq_live);irq_live=true;return 0;}
static void free_irq(unsigned irq,void *dev) {(void)irq;(void)dev;assert(irq_live);irq_live=false;}
static void irq_pre(struct msm_kms *k) {(void)k;}
static int irq_post(struct msm_kms *k) {(void)k;return fail_stage==4?-EIO:0;}
static void irq_off(struct msm_kms *k) {(void)k;}
static int aperture_remove_all_conflicting_devices(const char *name) {(void)name;return fail_stage==1?-EBUSY:0;}
static void drm_helper_move_panel_connectors_to_head(struct drm_device *d) {(void)d;}
static int drm_vblank_init(struct drm_device *d,unsigned n) {(void)d;(void)n;return fail_stage==2?-EIO:0;}
static void drm_kms_helper_poll_fini(struct drm_device *d) {(void)d;}
static void drm_mode_config_reset(struct drm_device *d) {(void)d;}
static int pm_runtime_get_sync(struct device *d) {(void)d;return 0;}
static void pm_runtime_put_sync(struct device *d) {(void)d;}
static struct msm_kms fixture_kms;static struct msm_drm_private priv;static struct drm_device drm;
static struct platform_device pdev;static struct msm_iommu iommu;static struct vm vm;
static struct drm_driver driver={"fixture"};
/* Actual helpers below resolve their dependencies through these declarations. */
static int msm_kms_fault_handler(void *,unsigned long,int,void *);
static inline void msm_kms_destroy(struct msm_kms *);
static inline int msm_kms_init(struct msm_kms *,const struct msm_kms_funcs *);
void msm_disp_snapshot_state(struct drm_device *);
void msm_disp_snapshot_destroy(struct drm_device *);
static void backend_destroy(struct msm_kms *k) {
 backend_destroys++;
 if(enforce_order){assert(!irq_live&&!k->dump_worker);for(unsigned i=0;i<MAX_CRTCS;i++)assert(!k->pending_timers[i].worker);}
 assert(hw_live);msm_kms_destroy(k);hw_live=false;
}
static int hw_init(struct msm_kms *k) {(void)k;return 0;}
static const struct msm_kms_funcs funcs={.hw_init=hw_init,.destroy=backend_destroy,.irq_preinstall=irq_pre,.irq_postinstall=irq_post,.irq_uninstall=irq_off};
static int backend_init(struct drm_device *d) {int ret=msm_kms_init(d->dev_private->kms,&funcs);if(ret)return ret;hw_live=true;return 0;}
C
cat > "$work/cases.c" <<'C'
static void reset(void) {
 memset(workers,0,sizeof(workers));worker_count=worker_calls=backend_destroys=queued_inflight=0;fail_worker=-1;fail_stage=0;
 fail_wq=irq_live=hw_live=enforce_order=race_timer=false;wq.alive=false;
 queue_block=queue_entered=queue_release=callback_entered=callback_release=clear_attempt=clear_done=destroy_attempt=false;
 fixture_kms=(struct msm_kms){.funcs=&funcs,.irq=7};priv=(struct msm_drm_private){&drm,&fixture_kms,backend_init};
 drm=(struct drm_device){.dev=&pdev.dev,.driver=&driver,.dev_private=&priv,.mode_config.num_crtc=MAX_CRTCS};
 for(unsigned i=0;i<MAX_CRTCS;i++)drm.crtcs[i]=(struct drm_crtc){.dev=&drm,.index=i,.base.id=(int)i};
 pdev.dev.drvdata=&priv;vm.mmu=&iommu.base;fixture_kms.dev=&drm;fixture_kms.vm=&vm;
 memset(&iommu,0,sizeof(iommu));msm_mmu_init(&iommu.base,&pdev.dev,NULL,MSM_MMU_IOMMU);
 watched_fault=&iommu.base.handler_lock;watched_dump=&fixture_kms.dump_lock;
}
static void no_workers(void) {for(unsigned i=0;i<worker_count;i++)assert(!workers[i].alive);assert(!wq.alive&&!irq_live);}
static void snapshot_failure(void) {reset();fail_worker=0;assert(msm_disp_snapshot_init(&drm)==-ENOMEM);assert(!fixture_kms.dump_worker&&!fixture_kms.dump_mutex.alive);no_workers();}
static void init_failure(void) {
 for(int fail=-1;fail<MAX_CRTCS;fail++){reset();if(fail<0)fail_wq=true;else fail_worker=fail;assert(msm_kms_init(&fixture_kms,&funcs)==-ENOMEM);no_workers();assert(!fixture_kms.wq);}
}
static void timer_case(void) {
 reset();assert(!msm_atomic_init_pending_timer(&fixture_kms.pending_timers[0],&fixture_kms,0));
 struct msm_pending_timer *t=&fixture_kms.pending_timers[0];t->work.timer.active=true;
 msm_atomic_destroy_pending_timer(t);assert(!t->work.timer.active&&!t->worker);
 msm_atomic_destroy_pending_timer(t);no_workers();
}
static void late_snapshot(void) {reset();assert(!msm_disp_snapshot_init(&drm));msm_disp_snapshot_destroy(&drm);msm_disp_snapshot_state(&drm);assert(!fixture_kms.dump_worker);no_workers();}
static int blocking_fault(void *arg,unsigned long address,int flags,void *data) {
 (void)arg;(void)address;(void)flags;(void)data;
 pthread_mutex_lock(&gate);callback_entered=true;pthread_cond_broadcast(&changed);await(&callback_release);pthread_mutex_unlock(&gate);return 17;
}
static void *fault_thread(void *unused) {(void)unused;assert(msm_disp_fault_handler(NULL,NULL,123,0,&iommu)==17);return NULL;}
static void *clear_thread(void *unused) {(void)unused;clearing=true;msm_mmu_set_fault_handler(&iommu.base,&fixture_kms,NULL);pthread_mutex_lock(&gate);clear_done=true;pthread_cond_broadcast(&changed);pthread_mutex_unlock(&gate);return NULL;}
static void fault_race(void) {
 reset();msm_mmu_set_fault_handler(&iommu.base,&fixture_kms,blocking_fault);pthread_t fault,clear;
 assert(!pthread_create(&fault,NULL,fault_thread,NULL));pthread_mutex_lock(&gate);await(&callback_entered);pthread_mutex_unlock(&gate);
 assert(!pthread_create(&clear,NULL,clear_thread,NULL));pthread_mutex_lock(&gate);
 struct timespec deadline;assert(!clock_gettime(CLOCK_REALTIME,&deadline));deadline.tv_sec+=5;
 while(!clear_attempt&&!clear_done)assert(!pthread_cond_timedwait(&changed,&gate,&deadline));
 assert(!clear_done);callback_release=true;pthread_cond_broadcast(&changed);pthread_mutex_unlock(&gate);
 assert(!pthread_join(fault,NULL)&&!pthread_join(clear,NULL));assert(clear_done&&!iommu.base.handler);
 assert(msm_disp_fault_handler(NULL,NULL,123,0,&iommu)==-ENOSYS);
}
static void *queue_thread(void *unused) {(void)unused;msm_disp_snapshot_state(&drm);return NULL;}
static void *snapshot_destroy_thread(void *unused) {(void)unused;destroying=true;msm_disp_snapshot_destroy(&drm);return NULL;}
static void snapshot_race(void) {
 reset();assert(!msm_disp_snapshot_init(&drm));queue_block=true;pthread_t queue,destroy;
 assert(!pthread_create(&queue,NULL,queue_thread,NULL));pthread_mutex_lock(&gate);await(&queue_entered);pthread_mutex_unlock(&gate);
 assert(!pthread_create(&destroy,NULL,snapshot_destroy_thread,NULL));pthread_mutex_lock(&gate);await(&destroy_attempt);
 queue_release=true;pthread_cond_broadcast(&changed);pthread_mutex_unlock(&gate);
 assert(!pthread_join(queue,NULL)&&!pthread_join(destroy,NULL));queue_block=false;
 msm_disp_snapshot_state(&drm);assert(!fixture_kms.dump_worker);no_workers();
}
static void common_paths(void) {
 for(int fail=0;fail<1+MAX_CRTCS*2;fail++){
  reset();fail_worker=fail;assert(msm_drm_kms_init(&pdev.dev,&driver)==-ENOMEM);no_workers();
  assert(!fixture_kms.dump_mutex.alive&&!hw_live);assert(backend_destroys==(unsigned)(fail>MAX_CRTCS));
 }
 for(int fail=1;fail<=4;fail++){
  reset();fail_stage=fail;assert(msm_drm_kms_init(&pdev.dev,&driver)<0);no_workers();assert(!hw_live&&!fixture_kms.irq_requested);
 }
 for(int iteration=0;iteration<32;iteration++){
  reset();assert(!msm_drm_kms_init(&pdev.dev,&driver));assert(irq_live&&hw_live&&iommu.base.handler==msm_kms_fault_handler);
  for(unsigned i=0;i<MAX_CRTCS;i++)fixture_kms.pending_timers[i].work.timer.active=true;
  enforce_order=race_timer=true;msm_drm_kms_uninit(&pdev.dev);no_workers();
  assert(!hw_live&&!fixture_kms.dump_worker&&!fixture_kms.irq_requested&&!iommu.base.handler);
 }
}
int main(int argc,char **argv) {
 if(argc==2){
  if(!strcmp(argv[1],"snapshot-failure"))snapshot_failure();
  else if(!strcmp(argv[1],"init-unwind"))init_failure();
  else if(!strcmp(argv[1],"timer"))timer_case();
  else if(!strcmp(argv[1],"late-snapshot"))late_snapshot();
  else if(!strcmp(argv[1],"fault-race"))fault_race();
  else if(!strcmp(argv[1],"snapshot-race"))snapshot_race();
  else assert(0);
  return 0;
 }
 snapshot_failure();init_failure();timer_case();late_snapshot();fault_race();snapshot_race();common_paths();
 puts("Actual KMS init/unwind, pending timer drain, IRQ ownership and concurrent fault/snapshot withdrawal passed; no hardware opened");return 0;
}
C
compile() {
    local tree=$1 output=$2 msm=$1/drivers/gpu/drm/msm
    cat "$work/preamble.c" > "$work/$output.c"
    for function in msm_mmu_init msm_mmu_set_fault_handler; do extract "$msm/msm_mmu.h" "$function" >> "$work/$output.c"; done
    extract "$msm/msm_iommu.c" msm_disp_fault_handler >> "$work/$output.c"
    for function in msm_hrtimer_worktimer msm_hrtimer_work_init; do extract "$msm/msm_io_utils.c" "$function" >> "$work/$output.c"; done
    for function in msm_atomic_init_pending_timer msm_atomic_destroy_pending_timer; do extract "$msm/msm_atomic.c" "$function" >> "$work/$output.c"; done
    extract "$msm/msm_kms.h" msm_kms_init >> "$work/$output.c"
    extract "$msm/msm_kms.h" msm_kms_stop_pending_timers true >> "$work/$output.c"
    extract "$msm/msm_kms.h" msm_kms_destroy >> "$work/$output.c"
    for function in msm_disp_snapshot_state msm_disp_snapshot_init msm_disp_snapshot_destroy; do extract "$msm/disp/msm_disp_snapshot.c" "$function" >> "$work/$output.c"; done
    for function in msm_irq_preinstall msm_irq_postinstall msm_irq_install msm_irq_uninstall msm_kms_fault_handler; do extract "$msm/msm_kms.c" "$function" >> "$work/$output.c"; done
    extract "$msm/msm_kms.c" msm_drm_kms_destroy_event_threads true >> "$work/$output.c"
    for function in msm_drm_kms_uninit msm_drm_kms_init; do extract "$msm/msm_kms.c" "$function" >> "$work/$output.c"; done
    cat "$work/cases.c" >> "$work/$output.c"
    "${CC:-clang}" -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-unused-function -Wno-unused-parameter -Wno-sign-compare -Wno-misleading-indentation \
        -pthread -fsanitize=undefined -fsanitize-undefined-trap-on-error "$work/$output.c" -o "$work/$output"
}
compile "$candidate" candidate
timeout 30 "$work/candidate"
compile "$baseline" baseline
for defect in snapshot-failure init-unwind timer late-snapshot fault-race snapshot-race; do
    if timeout 30 "$work/baseline" "$defect" > "$work/$defect.log" 2>&1; then code=0; else code=$?; fi
    [[ $code == 134 ]] || { printf 'Unmodified %s did not reach its assertion (status%s)\n' "$defect" "$code" >&2; cat "$work/$defect.log" >&2; exit 1; }
    printf 'Unmodified KMS %s assertion control refused\n' "$defect"
done
