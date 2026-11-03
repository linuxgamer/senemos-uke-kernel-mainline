#!/usr/bin/env bash
# COPR-only: real destination ownership, timeout, reset and preparation functions.
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
relative=drivers/gpu/drm/msm/disp/dpu1/dpu_encoder_phys_wb.c
source=$candidate/$relative
cat > "$work/preamble.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uint32_t u32;
#define container_of(p,t,m) ((t *)((char *)(p)-__builtin_offsetof(t,m)))
#define to_dpu_encoder_phys_wb(p) container_of(p,struct dpu_encoder_phys_wb,base)
#define READ_ONCE(x) __atomic_load_n(&(x),__ATOMIC_RELAXED)
#define WRITE_ONCE(x,v) __atomic_store_n(&(x),(v),__ATOMIC_RELAXED)
#define WARN_ON_ONCE(x) (x)
static void debug_log(const char *fmt,...) {(void)fmt;}
#define DPU_DEBUG(...) debug_log(__VA_ARGS__)
#define DPU_ERROR(...) ((void)0)
#define DPU_ENCODER_FRAME_EVENT_ERROR 1
#define DPU_ENCODER_FRAME_EVENT_DONE 0
#define DPU_ENC_DISABLED 0
#define DPU_ENC_ENABLED 1
#define DPU_ENC_ERR_NEEDS_HW_RESET 2
#define WB_0 0
#define INTR_IDX_WB_DONE 0
#define KICKOFF_TIMEOUT_MS 80
#define MDP_PLANE_PLANAR 1
#define C1_B_Cb 1
#define GFP_KERNEL 0
#define swap(a,b) do {__typeof__(a) _tmp=(a);(a)=(b);(b)=_tmp;}while(0)
typedef pthread_mutex_t spinlock_t;
#define spin_lock_irqsave(l,f) do {(f)=0;assert(!pthread_mutex_lock(l));}while(0)
#define spin_unlock_irqrestore(l,f) do {(void)(f);assert(!pthread_mutex_unlock(l));}while(0)
typedef int atomic_t;
static bool atomic_add_unless(atomic_t *a,int n,int unless) {if(*a==unless)return false;*a+=n;return true;}
struct drm_device {int refs;};
struct drm_crtc_state {bool clone;};
struct drm_crtc {struct drm_crtc_state *state;};
struct drm_encoder {struct drm_device *dev;struct drm_crtc *crtc;};
static bool drm_crtc_in_clone_mode(struct drm_crtc_state *s) {return s->clone;}
struct drm_framebuffer {unsigned width,height,pins,id;};
struct drm_writeback_job;
struct drm_connector_state {struct drm_writeback_job *writeback_job;};
struct drm_connector {struct drm_connector_state *state;};
struct drm_writeback_connector {struct drm_connector base;struct drm_writeback_job *queued;unsigned signals;int status;};
struct drm_writeback_job {struct drm_framebuffer *fb;struct drm_writeback_connector *connector;void *priv;};
/* DPU_MAX_PLANES is four in the pinned dpu_hw_mdss.h. */
struct dpu_hw_fmt_layout {unsigned width,height,num_planes,plane_addr[4],plane_pitch[4];};
struct dpu_hw_wb_cfg {struct dpu_hw_fmt_layout dest;};
struct dpu_hw_ctl;
struct dpu_hw_ctl {struct {void (*clear_pending_flush)(struct dpu_hw_ctl *);} ops;};
struct dpu_hw_wb {int idx;};
struct mdss_ver {int core_major_ver;};
struct catalog {struct mdss_ver *mdss_ver;};
struct dpu_kms {struct catalog *catalog;};
struct dpu_encoder_phys {struct drm_encoder *parent;spinlock_t *enc_spinlock;atomic_t pending_kickoff_cnt;int pending_kickoff_wq,enable_state,retire_disable_error,irq[1];struct dpu_hw_wb *hw_wb;struct dpu_hw_ctl *hw_ctl;struct dpu_kms *dpu_kms;};
struct dpu_encoder_phys_wb {struct dpu_encoder_phys base;int wb_done_timeout_cnt;struct dpu_hw_wb_cfg wb_cfg;struct drm_writeback_job *wb_job;struct drm_writeback_connector *wb_conn,*active_conn;bool wb_failed,clone_mode;};
struct dpu_encoder_wait_info {int *wq;atomic_t *atomic_cnt;int timeout_ms;};
struct msm_format {unsigned num_planes,fetch_type,element[1];};
static struct msm_format format={.num_planes=2};
static bool allocation_fail,hardware_busy;
static int prepare_error,size_error,wait_error,reset_error;
static unsigned allocations,pin_calls,unpin_calls,prepared_id,vblanks;
static void *kzalloc(size_t n,int flags) {(void)flags;if(allocation_fail)return NULL;++allocations;return calloc(1,n);}
static void kfree(void *p) {assert(allocations);--allocations;free(p);}
static int msm_framebuffer_prepare(struct drm_framebuffer *fb,bool scanout) {(void)scanout;++pin_calls;if(prepare_error)return prepare_error;++fb->pins;return 0;}
static void msm_framebuffer_cleanup(struct drm_framebuffer *fb,bool scanout) {(void)scanout;assert(!hardware_busy&&fb->pins==1);--fb->pins;++unpin_calls;}
static const struct msm_format *msm_framebuffer_format(struct drm_framebuffer *fb) {(void)fb;return &format;}
static int dpu_format_populate_plane_sizes(struct drm_framebuffer *fb,struct dpu_hw_fmt_layout *l) {(void)fb;(void)l;return size_error;}
static void dpu_format_populate_addrs(struct drm_framebuffer *fb,struct dpu_hw_fmt_layout *l) {l->plane_addr[0]=fb->id;}
static void drm_dev_get(struct drm_device *d) {assert(d->refs);++d->refs;}
static void drm_dev_put(struct drm_device *d) {assert(d->refs>1);--d->refs;}
static void drm_writeback_queue_job(struct drm_writeback_connector *c,struct drm_connector_state *s) {assert(!c->queued&&s->writeback_job);c->queued=s->writeback_job;s->writeback_job=NULL;}
static struct dpu_encoder_phys *physical;
static void dpu_encoder_phys_wb_cleanup_wb_job(struct dpu_encoder_phys *,struct drm_writeback_job *);
static void drm_writeback_signal_completion(struct drm_writeback_connector *c,int status) {
 assert(!hardware_busy&&c->queued);struct drm_writeback_job *job=c->queued;c->queued=NULL;++c->signals;c->status=status;
 dpu_encoder_phys_wb_cleanup_wb_job(physical,job);
}
static void msm_disp_snapshot_state(struct drm_device *d) {(void)d;}
static void dpu_encoder_frame_done_callback(struct drm_encoder *e,struct dpu_encoder_phys *p,u32 event) {(void)e;(void)p;(void)event;}
static void dpu_encoder_vblank_callback(struct drm_encoder *e,struct dpu_encoder_phys *p) {(void)e;(void)p;++vblanks;}
static void wake_up_all(int *w) {(void)w;}
static int dpu_encoder_helper_wait_for_irq(struct dpu_encoder_phys *p,int irq,void (*cb)(void *),struct dpu_encoder_wait_info *w) {(void)p;(void)irq;(void)cb;(void)w;return wait_error;}
static void dpu_encoder_phys_wb_setup(struct dpu_encoder_phys *p,struct drm_framebuffer *fb) {prepared_id=fb->id;assert(to_dpu_encoder_phys_wb(p)->wb_cfg.dest.plane_addr[0]==fb->id);}
static void _dpu_encoder_phys_wb_update_flush(struct dpu_encoder_phys *p) {(void)p;}
static void clear_pending_flush(struct dpu_hw_ctl *c) {(void)c;}
static void dpu_encoder_helper_phys_cleanup(struct dpu_encoder_phys *p) {p->retire_disable_error=reset_error;if(!reset_error)hardware_busy=false;}
C
awk '/^struct dpu_wb_job \{/ {emit=1;found=1} emit {print} emit&&/^};/ {exit} END {if(!found)exit 1}' "$source" >> "$work/preamble.c"
for name in dpu_encoder_phys_wb_complete dpu_encoder_phys_wb_done_irq \
 _dpu_encoder_phys_wb_handle_wbdone_timeout dpu_encoder_phys_wb_wait_for_commit_done \
 dpu_encoder_phys_wb_prepare_for_kickoff dpu_encoder_phys_wb_disable \
 dpu_encoder_phys_wb_prepare_wb_job dpu_encoder_phys_wb_cleanup_wb_job \
 dpu_encoder_phys_wb_is_valid_for_commit; do
 extract "$source" "$name" >> "$work/preamble.c"
done
cat >> "$work/preamble.c" <<'C'
struct sample {spinlock_t lock;struct drm_device dev;struct drm_encoder encoder;struct drm_crtc crtc;struct drm_crtc_state crtc_state;struct drm_framebuffer fb[2];struct drm_connector_state state;struct drm_writeback_connector conn;struct drm_writeback_job job[2];struct dpu_encoder_phys_wb wb;struct dpu_hw_ctl ctl;struct dpu_hw_wb hw;struct mdss_ver ver;struct catalog cat;struct dpu_kms kms;};
static struct sample *sample(void) {
 struct sample *s=calloc(1,sizeof(*s));assert(s);assert(!pthread_mutex_init(&s->lock,NULL));s->dev.refs=1;s->encoder.dev=&s->dev;
 s->crtc.state=&s->crtc_state;s->encoder.crtc=&s->crtc;
 s->conn.base.state=&s->state;for(unsigned i=0;i<2;++i){s->fb[i]=(struct drm_framebuffer){.width=100,.height=100,.id=i+1};s->job[i]=(struct drm_writeback_job){.fb=&s->fb[i],.connector=&s->conn};}
 s->ctl.ops.clear_pending_flush=clear_pending_flush;s->ver.core_major_ver=11;s->cat.mdss_ver=&s->ver;s->kms.catalog=&s->cat;
 s->wb.base=(struct dpu_encoder_phys){.parent=&s->encoder,.enc_spinlock=&s->lock,.hw_ctl=&s->ctl,.hw_wb=&s->hw,.dpu_kms=&s->kms,.enable_state=DPU_ENC_ENABLED};s->wb.wb_conn=&s->conn;physical=&s->wb.base;
 return s;
}
static void queue(struct sample *s) {
 assert(!dpu_encoder_phys_wb_prepare_wb_job(physical,&s->job[0]));s->state.writeback_job=&s->job[0];assert(dpu_encoder_phys_wb_is_valid_for_commit(physical));
 s->wb.clone_mode=drm_crtc_in_clone_mode(&s->crtc_state);
 dpu_encoder_phys_wb_prepare_for_kickoff(physical);assert(s->conn.queued==&s->job[0]&&s->dev.refs==2&&prepared_id==1);physical->pending_kickoff_cnt=1;hardware_busy=true;
}
static void *complete_thread(void *p) {dpu_encoder_phys_wb_complete(p,0);return NULL;}
C
cp "$work/preamble.c" "$work/candidate.c"
cat >> "$work/candidate.c" <<'C'
int main(void) {
 struct sample *s=sample();allocation_fail=true;unsigned pins=pin_calls;assert(dpu_encoder_phys_wb_prepare_wb_job(physical,&s->job[0])==-ENOMEM&&pin_calls==pins&&!allocations);allocation_fail=false;
 prepare_error=-EIO;assert(dpu_encoder_phys_wb_prepare_wb_job(physical,&s->job[0])==-EIO&&!allocations);prepare_error=0;
 size_error=-EINVAL;assert(dpu_encoder_phys_wb_prepare_wb_job(physical,&s->job[0])==-EINVAL&&!allocations&&!s->fb[0].pins);size_error=0;
 queue(s);assert(!dpu_encoder_phys_wb_prepare_wb_job(physical,&s->job[1]));assert(s->wb.wb_cfg.dest.plane_addr[0]==1&&s->conn.queued==&s->job[0]);
 _dpu_encoder_phys_wb_handle_wbdone_timeout(physical);assert(!s->conn.signals&&s->fb[0].pins==1&&s->wb.active_conn&&s->dev.refs==2);
 assert(dpu_encoder_phys_wb_wait_for_commit_done(physical)==-ETIMEDOUT&&dpu_encoder_phys_wb_prepare_wb_job(physical,&s->job[0])==-EIO);
 hardware_busy=false;dpu_encoder_phys_wb_done_irq(physical);assert(s->conn.signals==1&&s->conn.status==-ETIMEDOUT&&!s->fb[0].pins&&s->dev.refs==1&&s->fb[1].pins==1);
 dpu_encoder_phys_wb_cleanup_wb_job(physical,&s->job[1]);assert(!allocations);dpu_encoder_phys_wb_complete(physical,0);assert(s->conn.signals==1);
 for(unsigned failed=0;failed<2;++failed) {
  s=sample();queue(s);_dpu_encoder_phys_wb_handle_wbdone_timeout(physical);reset_error=failed?-EIO:0;
  dpu_encoder_phys_wb_disable(physical);assert((s->fb[0].pins==1)==(bool)failed&&s->conn.signals==!failed);
  if(failed){assert(s->dev.refs==2&&s->wb.wb_failed&&s->wb.active_conn);reset_error=0;dpu_encoder_phys_wb_disable(physical);assert(s->fb[0].pins==1);hardware_busy=false;dpu_encoder_phys_wb_complete(physical,0);}
  assert(s->dev.refs==1&&s->conn.status==-ETIMEDOUT&&!allocations);
 }
 s=sample();queue(s);hardware_busy=false;dpu_encoder_phys_wb_done_irq(physical);assert(s->conn.signals==1&&!s->conn.status&&!allocations);
 s=sample();s->crtc_state.clone=true;queue(s);unsigned before=vblanks;hardware_busy=false;dpu_encoder_phys_wb_done_irq(physical);assert(vblanks==before&&s->conn.signals==1&&!allocations);
 s=sample();queue(s);reset_error=0;dpu_encoder_phys_wb_disable(physical);assert(s->conn.signals==1&&s->conn.status==-ECANCELED&&!allocations);
 for(unsigned i=0;i<64;++i) {
  s=sample();queue(s);_dpu_encoder_phys_wb_handle_wbdone_timeout(physical);hardware_busy=false;pthread_t a,b;
  assert(!pthread_create(&a,NULL,complete_thread,physical)&&!pthread_create(&b,NULL,complete_thread,physical));assert(!pthread_join(a,NULL)&&!pthread_join(b,NULL));
  assert(s->conn.signals==1&&s->conn.status==-ETIMEDOUT&&!s->fb[0].pins&&s->dev.refs==1&&!allocations);
 }
 assert(unpin_calls>=64);puts("Actual WB timeout keeps the queued pin; DONE/reset arbitrate one error completion; preallocation and per-job configuration pass");
}
C
"${CC:-clang}" -std=gnu11 -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter -Wno-unused-function \
 -fsanitize=undefined -fsanitize-undefined-trap-on-error -pthread "$work/candidate.c" -o "$work/candidate"
"$work/candidate"
# The unchanged parent timeout must hit the live-DMA completion assertion.
sed '/^static void _dpu_encoder_phys_wb_handle_wbdone_timeout(/,$d' "$work/preamble.c" > "$work/parent.c"
extract "$baseline/$relative" _dpu_encoder_phys_wb_handle_wbdone_timeout >> "$work/parent.c"
# Parent control has no successful preparation; emulate its existing queued pin.
cat >> "$work/parent.c" <<'C'
static void dpu_encoder_phys_wb_cleanup_wb_job(struct dpu_encoder_phys *p,struct drm_writeback_job *j) {(void)p;msm_framebuffer_cleanup(j->fb,false);}
int main(void) {
 struct drm_device dev={.refs=1};struct drm_encoder enc={.dev=&dev};spinlock_t lock=PTHREAD_MUTEX_INITIALIZER;
 struct drm_framebuffer fb={.pins=1};struct drm_writeback_job job={.fb=&fb};struct drm_writeback_connector conn={.queued=&job};
 struct dpu_encoder_phys_wb wb={.base={.parent=&enc,.enc_spinlock=&lock,.pending_kickoff_cnt=1},.wb_conn=&conn};
 physical=&wb.base;hardware_busy=true;_dpu_encoder_phys_wb_handle_wbdone_timeout(physical);assert(!conn.signals&&fb.pins==1);
 (void)allocations;(void)pin_calls;(void)unpin_calls;(void)prepared_id;(void)vblanks;
}
C
"${CC:-clang}" -std=gnu11 -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter -Wno-unused-function \
 -fsanitize=undefined -fsanitize-undefined-trap-on-error -pthread "$work/parent.c" -o "$work/parent"
set +e
"$work/parent" > "$work/parent.log" 2>&1
status=$?
set -e
cat "$work/parent.log"
[[ $status == 134 ]]
printf 'Parent actual WB timeout refuses completion during live DMA: assertion status %s\n' "$status"
