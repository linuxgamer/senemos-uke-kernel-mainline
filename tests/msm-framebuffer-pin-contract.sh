#!/usr/bin/env bash
# COPR-only actual-function fixture; no DRM node, driver or device is opened.
set -Eeuo pipefail
ulimit -c 0
kernel=${1:?Pass the prepared kernel source}
baseline=${2:?Pass the pre-patch msm_fb.c}
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
extract() {
    local file=$1 name=$2
    awk -v name="$name" '
        $0 ~ "^(static )?(int|void) " name "\\(" {emit=1}
        emit {print}
        emit && /^}/ {exit}' "$file"
}
cat > "$work/preamble.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
typedef uint64_t u64;
typedef _Atomic int atomic_t;
typedef _Atomic int refcount_t;
static int atomic_inc_return(atomic_t *v) { return atomic_fetch_add(v,1)+1; }
static int atomic_dec_return(atomic_t *v) { return atomic_fetch_sub(v,1)-1; }
static void atomic_dec(atomic_t *v) { atomic_fetch_sub(v,1); }
static void refcount_inc(refcount_t *v) { atomic_fetch_add(v,1); }
static void refcount_dec(refcount_t *v) { atomic_fetch_sub(v,1); }
struct mutex { pthread_mutex_t native; };
static void mutex_init(struct mutex *m) { assert(!pthread_mutex_init(&m->native,NULL)); }
static void mutex_destroy(struct mutex *m) { assert(!pthread_mutex_destroy(&m->native)); }
static struct mutex *take_lock(struct mutex *m) { assert(!pthread_mutex_lock(&m->native)); return m; }
static void drop_lock(struct mutex **m) { assert(!pthread_mutex_unlock(&(*m)->native)); }
#define guard(kind) struct mutex *held_lock __attribute__((cleanup(drop_lock))) = take_lock
#define DRM_FORMAT_MAX_PLANES 4
#define drm_dbg_state(...) ((void)0)
#define DPU_ERROR(...) ((void)0)
#define DPU_DEBUG(...) ((void)0)
#define swap(a,b) do { __typeof__(a) t=(a); (a)=(b); (b)=t; } while(0)
#define MDP_PLANE_PLANAR 1
#define C1_B_Cb 2
struct drm_gpuvm { int unused; };
struct msm_kms { struct drm_gpuvm *vm; };
struct msm_drm_private { struct msm_kms *kms; };
struct drm_device { struct msm_drm_private *dev_private; };
struct drm_gem_object { int refs,pins; uint64_t address; };
struct drm_format_info { int num_planes; };
struct drm_framebuffer { struct drm_device *dev; const struct drm_format_info *format; struct drm_gem_object *obj[4]; unsigned width,height; struct {unsigned id;} base; };
struct msm_format { int num_planes,fetch_type,element[4]; };
#define to_msm_framebuffer(fb) ((struct msm_framebuffer *)(fb))
static int calls,fail_at,format_error,format_calls,format_fail_at;
static bool block_first,first_entered,release_first,second_started,second_done;
static pthread_mutex_t gate=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed=PTHREAD_COND_INITIALIZER;
static void msm_gem_vma_get(struct drm_gem_object *o) { ++o->refs; }
static void msm_gem_vma_put(struct drm_gem_object *o) { assert(o->refs>0); --o->refs; }
static int msm_gem_get_and_pin_iova(struct drm_gem_object *o,struct drm_gpuvm *v,uint64_t *addr) {
    (void)v; int index=calls++;
    if(block_first && index==0) {
        assert(!pthread_mutex_lock(&gate)); first_entered=true; pthread_cond_broadcast(&changed);
        while(!release_first) pthread_cond_wait(&changed,&gate);
        assert(!pthread_mutex_unlock(&gate));
    }
    if(index==fail_at) return -ENOMEM;
    ++o->pins; *addr=o->address; return 0;
}
static void msm_gem_unpin_iova(struct drm_gem_object *o,struct drm_gpuvm *v) { (void)v; assert(o->pins>0); --o->pins; }
C
cat > "$work/writeback.c" <<'C'
struct drm_writeback_connector { int unused; };
struct drm_writeback_job { struct drm_framebuffer *fb; struct drm_writeback_connector *connector; };
struct wb_dest { uint32_t plane_addr[4],plane_pitch[4]; unsigned width,height,num_planes; };
struct dpu_hw_wb_cfg { struct wb_dest dest; };
struct dpu_encoder_phys;
struct dpu_encoder_phys_ops { int (*prepare_wb_job)(struct dpu_encoder_phys *,struct drm_writeback_job *); void (*cleanup_wb_job)(struct dpu_encoder_phys *,struct drm_writeback_job *); };
struct dpu_encoder_phys { struct dpu_encoder_phys_ops ops; void *owner; };
struct dpu_encoder_phys_wb { struct dpu_encoder_phys base; struct dpu_hw_wb_cfg wb_cfg; struct drm_writeback_job *wb_job; struct drm_writeback_connector *wb_conn; };
struct dpu_encoder_virt { int num_phys_encs; struct dpu_encoder_phys *phys_encs[3]; };
struct drm_encoder { struct dpu_encoder_virt *owner; };
struct dpu_wb_connector { struct drm_writeback_connector base; struct drm_encoder *wb_enc; };
#define to_dpu_encoder_phys_wb(p) ((struct dpu_encoder_phys_wb *)(p))
#define to_dpu_encoder_virt(e) ((e)->owner)
#define to_dpu_wb_conn(c) ((struct dpu_wb_connector *)(c))
static struct msm_format *msm_framebuffer_format(struct drm_framebuffer *fb) { return (struct msm_format *)to_msm_framebuffer(fb)->format; }
static int dpu_format_populate_plane_sizes(struct drm_framebuffer *fb,struct wb_dest *dest) { (void)fb;(void)dest;return format_calls++==format_fail_at?format_error:0; }
static void dpu_format_populate_addrs(struct drm_framebuffer *fb,struct wb_dest *dest) { for(int i=0;i<fb->format->num_planes;i++)dest->plane_addr[i]=(uint32_t)to_msm_framebuffer(fb)->iova[i]; }
C
cat > "$work/cases.c" <<'C'
static struct drm_gpuvm vm;
static struct msm_kms kms={&vm};
static struct msm_drm_private priv={&kms};
static struct drm_device dev={&priv};
static struct drm_format_info info;
static struct msm_format format;
static struct drm_gem_object objects[4];
static struct msm_framebuffer fb;
static void setup(int n,bool shared) {
    memset(&fb,0,sizeof(fb)); memset(objects,0,sizeof(objects));
    info.num_planes=n; format=(struct msm_format){.num_planes=n};
    fb.base.dev=&dev; fb.base.format=&info; fb.format=&format;
    fb.base.width=128;fb.base.height=128;
    for(int i=0;i<n;i++){ objects[i].address=0x100000U+(unsigned)i*0x10000U; fb.base.obj[i]=&objects[shared?0:i]; }
    atomic_init(&fb.prepare_count,0);atomic_init(&fb.dirtyfb,1);
#ifdef FIXED_PIN_LOCK
    mutex_init(&fb.pin_lock);
#endif
    calls=0;fail_at=-1;format_error=0;format_calls=0;format_fail_at=0;block_first=false;
}
static void finish(void) {
    assert(atomic_load(&fb.prepare_count)==0 && atomic_load(&fb.dirtyfb)==1);
    for(int i=0;i<4;i++)assert(objects[i].refs==0 && objects[i].pins==0 && fb.iova[i]==0);
#ifdef FIXED_PIN_LOCK
    mutex_destroy(&fb.pin_lock);
#endif
}
static void failure_cases(void) {
    for(int n=1;n<=4;n++)for(int shared=0;shared<2;shared++)for(int dirty=0;dirty<2;dirty++)for(int fail=0;fail<n;fail++) {
        setup(n,shared);fail_at=fail;
        assert(msm_framebuffer_prepare(&fb.base,dirty)==-ENOMEM);
        assert(atomic_load(&fb.prepare_count)==0 && atomic_load(&fb.dirtyfb)==1);
        for(int i=0;i<4;i++)assert(objects[i].refs==0 && objects[i].pins==0 && fb.iova[i]==0);
        fail_at=-1;
        assert(msm_framebuffer_prepare(&fb.base,dirty)==0);
        for(int i=0;i<n;i++)assert(fb.iova[i]==fb.base.obj[i]->address);
        assert(msm_framebuffer_prepare(&fb.base,!dirty)==0);
        assert(calls==fail+1+n);
        msm_framebuffer_cleanup(&fb.base,dirty);
        for(int i=0;i<n;i++)assert(fb.iova[i]!=0);
        msm_framebuffer_cleanup(&fb.base,!dirty);finish();
    }
}
static void *first_prepare(void *unused) { (void)unused;assert(msm_framebuffer_prepare(&fb.base,false)==0);return NULL; }
static void *second_prepare(void *unused) {
    (void)unused;pthread_mutex_lock(&gate);second_started=true;pthread_cond_broadcast(&changed);pthread_mutex_unlock(&gate);
    assert(msm_framebuffer_prepare(&fb.base,false)==0);
    pthread_mutex_lock(&gate);second_done=true;pthread_cond_broadcast(&changed);pthread_mutex_unlock(&gate);return NULL;
}
static void race_case(void) {
    pthread_t first,second;setup(2,false);block_first=true;
    first_entered=release_first=second_started=second_done=false;
    assert(!pthread_create(&first,NULL,first_prepare,NULL));pthread_mutex_lock(&gate);
    while(!first_entered)pthread_cond_wait(&changed,&gate);
    pthread_mutex_unlock(&gate);assert(!pthread_create(&second,NULL,second_prepare,NULL));pthread_mutex_lock(&gate);
    while(!second_started)pthread_cond_wait(&changed,&gate);
    struct timespec deadline;clock_gettime(CLOCK_REALTIME,&deadline);deadline.tv_sec++;
    int ret=0;while(!second_done && ret!=ETIMEDOUT)ret=pthread_cond_timedwait(&changed,&gate,&deadline);
    bool premature=second_done;release_first=true;pthread_cond_broadcast(&changed);pthread_mutex_unlock(&gate);
    pthread_join(first,NULL);pthread_join(second,NULL);
    assert(!premature);
    for(int i=0;i<2;i++)assert(fb.iova[i]==objects[i].address && objects[i].refs==1 && objects[i].pins==1);
    msm_framebuffer_cleanup(&fb.base,false);msm_framebuffer_cleanup(&fb.base,false);finish();
}
static void writeback_cases(void) {
    for(int which=0;which<4;which++) {
        struct dpu_encoder_phys_wb wb[2]={0};struct dpu_encoder_virt enc={.num_phys_encs=2};struct drm_encoder drm_enc={&enc};
        struct dpu_wb_connector connector={.wb_enc=&drm_enc};struct drm_writeback_job job={&fb.base,&connector.base};
        setup(2,false);
        for(int i=0;i<2;i++) {wb[i].base.ops.prepare_wb_job=dpu_encoder_phys_wb_prepare_wb_job;wb[i].base.ops.cleanup_wb_job=dpu_encoder_phys_wb_cleanup_wb_job;enc.phys_encs[i]=&wb[i].base;}
        if(which==0)fail_at=0;
        if(which==1 || which==3)format_error=-EINVAL;
        if(which==3)format_fail_at=1;
        int ret=dpu_wb_conn_prepare_job(&connector.base,&job);
        if(which!=2) {assert(ret==(which==0?-ENOMEM:-EINVAL));assert(!wb[0].wb_job && !wb[1].wb_job);}
        else {assert(ret==0 && wb[0].wb_job==&job && wb[1].wb_job==&job);dpu_encoder_phys_wb_cleanup_wb_job(&wb[0].base,&job);dpu_encoder_phys_wb_cleanup_wb_job(&wb[1].base,&job);}
        finish();
    }
}
int main(int argc,char **argv) {
    if(argc==2 && !strcmp(argv[1],"failure")){failure_cases();return 0;}
    if(argc==2 && !strcmp(argv[1],"race")){race_case();return 0;}
    failure_cases();race_case();writeback_cases();
    puts("Actual framebuffer pin/error/retry/shared-plane/concurrent-prepare and writeback failure/cleanup paths passed; no hardware opened");return 0;
}
C
build_fixture() {
    local source=$1 output=$2
    cat "$work/preamble.c" > "$work/combined.c"
    if grep -q 'struct mutex pin_lock;' "$source"; then printf '#define FIXED_PIN_LOCK 1\n' >> "$work/combined.c"; fi
    awk '/^struct msm_framebuffer {/ {emit=1} emit {print} emit && /^};/ {exit}' "$source" >> "$work/combined.c"
    extract "$source" msm_framebuffer_unpin_planes >> "$work/combined.c"
    extract "$source" msm_framebuffer_prepare >> "$work/combined.c"
    extract "$source" msm_framebuffer_cleanup >> "$work/combined.c"
    cat "$work/writeback.c" >> "$work/combined.c"
    for name in dpu_encoder_phys_wb_prepare_wb_job dpu_encoder_phys_wb_cleanup_wb_job; do extract "$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_encoder_phys_wb.c" "$name" >> "$work/combined.c"; done
    extract "$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_encoder.c" dpu_encoder_prepare_wb_job >> "$work/combined.c"
    extract "$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_writeback.c" dpu_wb_conn_prepare_job >> "$work/combined.c"
    cat "$work/cases.c" >> "$work/combined.c"
    "${CC:-clang}" -std=gnu11 -O1 -g -Wall -Wextra -Werror -Wno-unused-function -pthread \
        -fsanitize=undefined -fno-sanitize-recover=all "$work/combined.c" -o "$output"
}
build_fixture "$kernel/drivers/gpu/drm/msm/msm_fb.c" "$work/fixed"
"$work/fixed"
build_fixture "$baseline" "$work/old"
for mode in failure race; do
    if "$work/old" "$mode" > "$work/old-$mode.log" 2>&1; then
        echo "Baseline incorrectly passed $mode control" >&2; exit 1
    fi
    grep -F 'Assertion' "$work/old-$mode.log" >/dev/null
    printf 'Unmodified baseline rejected by %s negative control\n' "$mode"
done
