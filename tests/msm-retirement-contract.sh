#!/usr/bin/env bash
# COPR-only: real CRTC ownership functions and real timer-tail sections.
set -Eeuo pipefail
ulimit -c 0
candidate=${1:?Prepared candidate}
baseline=${2:?Prepared parent}
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
extract() {
 local file=$1 name=$2
 awk -v name="$name" '
 $0 ~ "^(static )?(inline )?(int|void|bool) " name "\\(" && $0 !~ /;[[:space:]]*$/ {emit=1;found=1}
 emit {print} emit && /^}/ {exit} END {if(!found)exit 1}' "$file"
}
msm=drivers/gpu/drm/msm
dpu=$candidate/$msm/disp/dpu1
cat > "$work/preamble.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
typedef uint64_t u64;
typedef long ktime_t;
#define container_of(p,t,m) ((t *)((char *)(p)-offsetof(t,m)))
struct list_head {struct list_head *next,*prev;};
#define LIST_HEAD(n) struct list_head n={&(n),&(n)}
static void INIT_LIST_HEAD(struct list_head *h) {h->next=h->prev=h;}
static bool list_empty(const struct list_head *h) {return h->next==h;}
static void list_add_tail(struct list_head *n,struct list_head *h) {
 n->prev=h->prev;n->next=h;h->prev->next=n;h->prev=n;
}
static void list_del_init(struct list_head *n) {
 n->prev->next=n->next;n->next->prev=n->prev;INIT_LIST_HEAD(n);
}
static void list_move_tail(struct list_head *n,struct list_head *h) {list_del_init(n);list_add_tail(n,h);}
#define list_first_entry_or_null(h,t,m) (list_empty(h)?NULL:container_of((h)->next,t,m))
#define list_for_each_entry_safe(p,n,h,m) \
 for(struct list_head *_p=(h)->next,*_next;_p!=(h)&&((_next=_p->next),(p)=container_of(_p,__typeof__(*(p)),m),(n)=container_of(_next,__typeof__(*(n)),m),1);_p=_next)
typedef pthread_mutex_t spinlock_t;
#define spin_lock_init(p) assert(!pthread_mutex_init(p,NULL))
#define spin_lock_irqsave(p,f) do {(f)=0;assert(!pthread_mutex_lock(p));}while(0)
#define spin_unlock_irqrestore(p,f) do {(void)(f);assert(!pthread_mutex_unlock(p));}while(0)
static unsigned warnings;
#define WARN_ON_ONCE(x) ((x)?(++warnings,true):false)
#define drm_warn(...) ((void)0)
struct drm_crtc;
struct kthread_work {void (*func)(struct kthread_work *);};
struct drm_vblank_work {struct kthread_work base;struct drm_crtc *crtc;u64 count;bool queued;};
#define to_drm_vblank_work(w) container_of(w,struct drm_vblank_work,base)
struct drm_crtc_state {bool modeset;};
struct drm_device {int unused;};
struct drm_plane_state {struct drm_crtc *crtc;void *fb;unsigned pins;};
struct drm_plane;
struct drm_plane_helper_funcs {void (*cleanup_fb)(struct drm_plane *,struct drm_plane_state *);};
struct drm_plane {const struct drm_plane_helper_funcs *helper_private;};
struct drm_atomic_commit {struct drm_device *dev;unsigned refs,hw_done,nplanes;struct drm_plane planes[4];struct drm_plane_state old_planes[4];struct drm_crtc_state *old_crtcs[2];};
C
awk '/^struct dpu_crtc_retire(_work)? \{/ {emit=1} emit {print} emit&&/^};/ {emit=0}' "$dpu/dpu_crtc.h" >> "$work/preamble.c"
cat >> "$work/preamble.c" <<'C'
struct dpu_crtc_state {struct drm_crtc_state base;struct dpu_crtc_retire_work retire;};
struct drm_crtc {struct drm_device *dev;unsigned idx;u64 count;bool ready;struct dpu_crtc_retire retire;};
#define to_dpu_crtc(c) (c)
#define to_dpu_crtc_state(s) container_of(s,struct dpu_crtc_state,base)
#define for_each_old_plane_in_state(s,p,o,i) for((i)=0;(unsigned)(i)<(s)->nplanes&&(((p)=&(s)->planes[i]),((o)=&(s)->old_planes[i]),1);++(i))
#define for_each_old_crtc_in_state(s,c,o,i) for((i)=0;(i)<2;++(i)) if(((o)=(s)->old_crtcs[i])&&((c)=crtcs[i]))
static struct drm_crtc *crtcs[2];
static struct drm_crtc_state *drm_atomic_get_old_crtc_state(struct drm_atomic_commit *s,struct drm_crtc *c) {return s->old_crtcs[c->idx];}
static struct drm_atomic_commit *drm_atomic_commit_get(struct drm_atomic_commit *s) {assert(s->refs);++s->refs;return s;}
static void drm_atomic_commit_put(struct drm_atomic_commit *s) {assert(s->refs>1);--s->refs;}
static bool drm_atomic_crtc_needs_modeset(struct drm_crtc_state *s) {return s->modeset;}
static u64 drm_crtc_vblank_count(struct drm_crtc *c) {return c->count;}
static void drm_crtc_vblank_on(struct drm_crtc *c) {c->ready=true;}
static void drm_crtc_vblank_off(struct drm_crtc *c) {(void)c;}
static struct drm_vblank_work *queued[128];
static unsigned nqueued;
static int schedule_result=1;
static unsigned cleanups;
static pthread_mutex_t gate=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed=PTHREAD_COND_INITIALIZER;
static bool block_cleanup,entered_cleanup,allow_cleanup,worker_running,off_done,flushing;
static void await(bool *p) {
 struct timespec t;assert(!clock_gettime(CLOCK_REALTIME,&t));t.tv_sec+=5;
 while(!*p)assert(!pthread_cond_timedwait(&changed,&gate,&t));
}
static void cleanup_fb(struct drm_plane *p,struct drm_plane_state *s) {
 (void)p;pthread_mutex_lock(&gate);
 if(block_cleanup){entered_cleanup=true;pthread_cond_broadcast(&changed);await(&allow_cleanup);}
 pthread_mutex_unlock(&gate);assert(s->pins==1);--s->pins;++cleanups;
}
static const struct drm_plane_helper_funcs plane_funcs={cleanup_fb};
static void drm_vblank_work_init(struct drm_vblank_work *w,struct drm_crtc *c,void (*f)(struct kthread_work *)) {*w=(struct drm_vblank_work){.base={f},.crtc=c};}
static int drm_vblank_work_schedule(struct drm_vblank_work *w,u64 count,bool next) {
 assert(!next);if(schedule_result!=1)return schedule_result;
 assert(!w->queued&&nqueued<128);w->queued=true;w->count=count;queued[nqueued++]=w;return 1;
}
static bool drm_vblank_work_cancel_sync(struct drm_vblank_work *w) {bool b=w->queued;w->queued=false;return b;}
static void drm_vblank_work_flush_all(struct drm_crtc *c) {
 assert(c->ready);pthread_mutex_lock(&gate);flushing=true;pthread_cond_broadcast(&changed);
 while(worker_running)assert(!pthread_cond_wait(&changed,&gate));pthread_mutex_unlock(&gate);
}
static void deliver(struct drm_crtc *c) {
 for(unsigned i=0;i<nqueued;++i)if(queued[i]->queued&&queued[i]->crtc==c&&queued[i]->count<=c->count) {
  queued[i]->queued=false;queued[i]->base.func(&queued[i]->base);
 }
}
C
sed '/^#include /d' "$dpu/dpu_crtc_retire.c" >> "$work/preamble.c"
cat >> "$work/preamble.c" <<'C'
struct msm_kms;
C
extract "$dpu/dpu_kms.c" dpu_kms_cleanup_planes >> "$work/preamble.c"
cat >> "$work/preamble.c" <<'C'
struct msm_hrtimer_work {int unused;};
struct msm_pending_timer {struct msm_hrtimer_work work;};
struct kms_funcs {
 void (*enable_commit)(struct msm_kms *),(*disable_commit)(struct msm_kms *);
 void (*flush_commit)(struct msm_kms *,unsigned),(*wait_flush)(struct msm_kms *,unsigned);
 void (*retire_flush)(struct msm_kms *,unsigned),(*complete_commit)(struct msm_kms *,unsigned);
 void (*cleanup_planes)(struct msm_kms *,struct drm_atomic_commit *);
};
struct msm_kms {struct kms_funcs *funcs;unsigned pending_crtc_mask;struct msm_pending_timer pending_timers[2];};
static struct msm_kms *kms;
static bool locked,flushed;
#define BIT(i) (1U<<(i))
#define HRTIMER_MODE_ABS 0
#define trace_msm_atomic_async_commit_start(...) ((void)0)
#define trace_msm_atomic_async_commit_finish(...) ((void)0)
#define trace_msm_atomic_flush_commit(...) ((void)0)
#define trace_msm_atomic_wait_flush_start(...) ((void)0)
#define trace_msm_atomic_wait_flush_finish(...) ((void)0)
#define trace_msm_atomic_commit_tail_finish(...) ((void)0)
#define WARN_ON(x) assert(!(x))
static void lock_crtcs(struct msm_kms *k,unsigned m) {(void)k;assert(m==1&&!locked);locked=true;}
static void unlock_crtcs(struct msm_kms *k,unsigned m) {(void)k;assert(m==1&&locked);locked=false;}
static void vblank_get(struct msm_kms *k,unsigned m) {(void)k;(void)m;}
static void vblank_put(struct msm_kms *k,unsigned m) {(void)k;(void)m;}
static unsigned drm_crtc_index(struct drm_crtc *c) {return c->idx;}
static unsigned drm_crtc_mask(struct drm_crtc *c) {return BIT(c->idx);}
static int drm_crtc_next_vblank_start(struct drm_crtc *c,ktime_t *v) {(void)c;*v=1;return 0;}
static ktime_t ktime_sub(ktime_t a,ktime_t b) {return a-b;}
static ktime_t ms_to_ktime(int m) {return m;}
static void msm_hrtimer_queue_work(struct msm_hrtimer_work *w,ktime_t t,int m) {(void)w;(void)t;(void)m;}
static void drm_atomic_helper_commit_hw_done(struct drm_atomic_commit *s) {++s->hw_done;}
static void drm_atomic_helper_cleanup_planes(struct drm_device *d,struct drm_atomic_commit *s) {
 (void)d;for(unsigned i=0;i<s->nplanes;++i)if(s->old_planes[i].fb)cleanup_fb(&s->planes[i],&s->old_planes[i]);
}
static void enable_commit(struct msm_kms *k) {(void)k;}
static void disable_commit(struct msm_kms *k) {(void)k;}
static void flush_commit(struct msm_kms *k,unsigned m) {(void)k;assert(locked&&m==1);flushed=true;}
static void wait_flush(struct msm_kms *k,unsigned m) {(void)k;(void)m;assert(locked);}
static void retire_flush(struct msm_kms *k,unsigned m) {(void)k;assert(locked&&flushed&&m==1);dpu_crtc_retire_flush(crtcs[0],true,false);}
static void complete_commit(struct msm_kms *k,unsigned m) {(void)k;(void)m;}
struct sample {struct drm_device dev;struct drm_crtc c[2];struct dpu_crtc_state old[2];struct drm_atomic_commit state;};
static struct sample *sample(unsigned groups) {
 struct sample *s=calloc(1,sizeof(*s));assert(s);s->state.dev=&s->dev;s->state.refs=1;s->state.nplanes=groups;
 for(unsigned i=0;i<2;++i){s->c[i].dev=&s->dev;s->c[i].idx=i;crtcs[i]=&s->c[i];dpu_crtc_retire_init(crtcs[i]);dpu_crtc_retire_vblank_on(crtcs[i]);s->state.old_crtcs[i]=&s->old[i].base;}
 for(unsigned i=0;i<groups;++i){s->state.planes[i].helper_private=&plane_funcs;s->state.old_planes[i]=(struct drm_plane_state){.crtc=&s->c[i],.fb=s,.pins=1};dpu_crtc_retire_prepare(&s->c[i],&s->state);}
 return s;
}
static void *worker(void *p) {struct drm_crtc *c=p;deliver(c);pthread_mutex_lock(&gate);worker_running=false;pthread_cond_broadcast(&changed);pthread_mutex_unlock(&gate);return NULL;}
static void *off_thread(void *p) {dpu_crtc_retire_vblank_off(p,true);pthread_mutex_lock(&gate);off_done=true;pthread_cond_broadcast(&changed);pthread_mutex_unlock(&gate);return NULL;}
C
for variant in candidate baseline; do
 input=$candidate
 [[ $variant != baseline ]] || input=$baseline
 cp "$work/preamble.c" "$work/$variant.c"
 extract "$input/$msm/msm_atomic.c" msm_atomic_async_commit >> "$work/$variant.c"
 cat >> "$work/$variant.c" <<'C'
static void async_tail(struct drm_atomic_commit *state) {
 struct drm_device *dev=state->dev;struct drm_crtc *async_crtc=crtcs[0];unsigned crtc_mask=1;bool async=true;
 (void)dev;(void)async;
C
 awk '/^void msm_atomic_commit_tail\(/ {tail=1} tail&&/^\tif \(async\) \{/ {emit=1;found=1} emit&&/^fallback:/ {exit} emit {print} END {if(!found)exit 1}' "$input/$msm/msm_atomic.c" >> "$work/$variant.c"
 cat >> "$work/$variant.c" <<'C'
fallback: assert(!"unexpected fallback");
}
static void async_contract(void) {
 struct sample *s=sample(1);struct kms_funcs funcs={enable_commit,disable_commit,flush_commit,wait_flush,retire_flush,complete_commit,dpu_kms_cleanup_planes};
 struct msm_kms k={.funcs=&funcs};kms=&k;locked=true;flushed=false;
 async_tail(&s->state);assert(!locked&&s->state.hw_done==1&&s->state.old_planes[0].pins==1&&s->state.refs==2&&!nqueued);
 msm_atomic_async_commit(kms,0);assert(!locked&&flushed&&s->state.old_planes[0].pins==1);
 ++crtcs[0]->count;deliver(crtcs[0]);assert(!s->state.old_planes[0].pins&&s->state.refs==1);
}
int main(void) {
 async_contract();
#ifndef PARENT_CONTROL
 struct drm_crtc early={0};dpu_crtc_retire_init(&early);dpu_crtc_retire_fini(&early);
 struct sample *s=sample(1);unsigned cleaned=cleanups;
 dpu_crtc_retire_flush(&s->c[0],true,false);++s->c[0].count;
 dpu_kms_cleanup_planes(NULL,&s->state);assert(s->state.old_planes[0].pins==1);deliver(&s->c[0]);assert(cleanups==cleaned+1&&s->state.refs==1);
 s=sample(2);cleaned=cleanups;dpu_kms_cleanup_planes(NULL,&s->state);assert(s->state.refs==3);
 dpu_crtc_retire_flush(&s->c[0],true,true);assert(cleanups==cleaned+1&&s->state.refs==2&&s->state.old_planes[1].pins==1);
 dpu_crtc_retire_vblank_off(&s->c[1],true);assert(cleanups==cleaned+2&&s->state.refs==1);
 s=sample(1);dpu_crtc_retire_vblank_off(&s->c[0],true);dpu_crtc_retire_vblank_on(&s->c[0]);dpu_kms_cleanup_planes(NULL,&s->state);assert(!s->state.old_planes[0].pins&&s->state.refs==1);
 for(int result=-EIO;result<=0;result+=EIO) {
  s=sample(1);schedule_result=result;dpu_kms_cleanup_planes(NULL,&s->state);dpu_crtc_retire_flush(&s->c[0],true,false);
  assert(s->state.old_planes[0].pins==1&&dpu_crtc_retire_failed(&s->c[0]));assert(dpu_crtc_retire_check(&s->c[0],&s->old[0].base)==-EIO);
  s->old[0].base.modeset=true;assert(!dpu_crtc_retire_check(&s->c[0],&s->old[0].base));dpu_crtc_retire_vblank_off(&s->c[0],true);assert(!s->state.old_planes[0].pins);
 }
 schedule_result=1;s=sample(1);dpu_kms_cleanup_planes(NULL,&s->state);dpu_crtc_retire_wait_status(&s->c[0],-ETIMEDOUT);dpu_crtc_retire_wait_status(&s->c[0],0);dpu_crtc_retire_flush(&s->c[0],true,true);
 assert(dpu_crtc_retire_quarantined(&s->c[0])&&s->state.old_planes[0].pins==1);dpu_crtc_retire_vblank_off(&s->c[0],false);assert(s->state.refs==2&&s->state.old_planes[0].pins==1);
 s=sample(1);s->state.old_crtcs[0]=NULL;dpu_kms_cleanup_planes(NULL,&s->state);assert(s->state.refs==2&&s->state.old_planes[0].pins==1&&dpu_crtc_retire_quarantined(&s->c[0]));
 s=sample(1);dpu_kms_cleanup_planes(NULL,&s->state);unsigned refs=s->state.refs;dpu_kms_cleanup_planes(NULL,&s->state);assert(s->state.refs==refs);dpu_crtc_retire_vblank_off(&s->c[0],true);assert(s->state.refs==1);
 s=sample(1);s->state.old_planes[0].crtc=NULL;dpu_kms_cleanup_planes(NULL,&s->state);assert(s->state.refs==1&&!s->state.old_planes[0].pins);
 s=sample(1);dpu_kms_cleanup_planes(NULL,&s->state);dpu_crtc_retire_flush(&s->c[0],true,false);dpu_crtc_retire_vblank_off(&s->c[0],true);++s->c[0].count;deliver(&s->c[0]);assert(s->state.refs==1&&!s->state.old_planes[0].pins);
 s=sample(1);dpu_kms_cleanup_planes(NULL,&s->state);dpu_crtc_retire_flush(&s->c[0],true,false);++s->c[0].count;
 pthread_t w,o;pthread_mutex_lock(&gate);block_cleanup=worker_running=true;flushing=false;assert(!pthread_create(&w,NULL,worker,&s->c[0]));await(&entered_cleanup);
 assert(!pthread_create(&o,NULL,off_thread,&s->c[0]));await(&flushing);assert(!off_done);allow_cleanup=true;pthread_cond_broadcast(&changed);pthread_mutex_unlock(&gate);
 assert(!pthread_join(w,NULL)&&!pthread_join(o,NULL));assert(off_done&&s->state.refs==1&&!s->state.old_planes[0].pins);
 assert(warnings>=2);puts("Actual retirement ownership, timer flush ordering, missing-state controls and running-worker drain pass");
#endif
 (void)drm_atomic_helper_cleanup_planes;(void)worker;(void)off_thread;
 (void)warnings;(void)cleanups;(void)entered_cleanup;(void)off_done;(void)flushing;
}
C
 flags=();[[ $variant != baseline ]] || flags+=(-DPARENT_CONTROL)
 "${CC:-clang}" -std=gnu11 -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter -Wno-unused-function \
  -fsanitize=undefined -fsanitize-undefined-trap-on-error -pthread "${flags[@]}" "$work/$variant.c" -o "$work/$variant"
 if [[ $variant == candidate ]];then "$work/$variant";else
  set +e
  "$work/$variant" > "$work/parent.log" 2>&1
  status=$?
  set -e
  cat "$work/parent.log"
  [[ $status == 134 ]]
  printf 'Parent actual async tail refuses premature cleanup: assertion status %s\n' "$status"
 fi
done
