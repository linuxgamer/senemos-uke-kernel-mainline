#!/usr/bin/env bash
# COPR-only: execute actual DRM/DPU init and unwind functions at each failure.
set -Eeuo pipefail
ulimit -c 0
candidate=${1:?Pass prepared candidate}
baseline=${2:?Pass preceding source}
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
extract() {
    local file=$1 name=$2 optional=${3:-false}
    awk -v name="$name" -v optional="$optional" '
      $0 ~ "^(static )?(int|void) " name "\\(" && $0 !~ /;[[:space:]]*$/ {emit=1;found=1}
      emit {print} emit && /^}/ {exit}
      END {if(!found && optional!="true")exit 1}' "$file"
}
cat > "$work/dpu-preamble.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint32_t u32;
#define ERR_PTR(n) ((void *)(intptr_t)(n))
#define PTR_ERR(p) ((int)(intptr_t)(p))
#define IS_ERR(p) ((uintptr_t)(p)>=(uintptr_t)-4095)
#define ARRAY_SIZE(x) (sizeof(x)/sizeof((x)[0]))
#define DPU_ERROR(...) ((void)0)
#define DPU_DEBUG(...) ((void)0)
#define pr_info(...) ((void)0)
#define DPU_MAX_IMG_WIDTH 8192
#define DPU_MAX_IMG_HEIGHT 8192
#define DPU_PERF_DEFAULT_MAX_CORE_CLK_RATE 412500000
struct device {void *of_node;};
struct platform_device {struct device dev;};
struct drm_crtc {bool refresh;};
struct drm_device {struct device *dev;struct {unsigned cursor_width,cursor_height,min_width,min_height,max_width,max_height;} mode_config;unsigned max_vblank_count;bool vblank_disable_immediate;unsigned count;struct drm_crtc crtcs[2];};
struct msm_mmu;
struct msm_mmu_funcs {void (*detach)(struct msm_mmu *);};
struct msm_mmu {const struct msm_mmu_funcs *funcs;};
struct drm_gpuvm {struct msm_mmu *mmu;};
struct msm_kms {struct drm_gpuvm *vm;void *dp[2];};
struct dpu_hw_vbif {int value;};
struct dpu_vbif_cfg {int value;};
struct hw_mdp {struct {void (*dp_phy_intf_sel)(struct hw_mdp *,unsigned *);} ops;};
struct catalog {void *mdp,*perf;const struct dpu_vbif_cfg *vbif;int mdss_ver;};
struct dpu_kms {struct msm_kms base;struct drm_device *dev;struct platform_device *pdev;void *mmio,*mdss,*hw_intr;struct hw_mdp *hw_mdp;struct dpu_hw_vbif *hw_vbif;const struct catalog *catalog;int global_state,bandwidth_ref,rm,vbif,perf;};
#define to_dpu_kms(p) ((struct dpu_kms *)(p))
#define to_msm_vm(p) (p)
#define drm_for_each_crtc(c,d) for((c)=(d)->crtcs;(c)<(d)->crtcs+(d)->count;(c)++)
static int fail_at,pm_refs,global_live,vm_live,mmu_live,refresh_cleanups;
static const int dpu_kms_global_state_funcs;
static struct hw_mdp hw_mdp;static struct dpu_hw_vbif hw_vbif;static int intr,mdss;
static struct catalog catalog;
static void detach(struct msm_mmu *m) {(void)m;assert(mmu_live);mmu_live=0;}
static const struct msm_mmu_funcs mmu_funcs={detach};
static struct msm_mmu mmu={&mmu_funcs};static struct drm_gpuvm vm={&mmu};
static void drm_atomic_private_obj_init(struct drm_device *d,int *state,const int *funcs) {(void)d;(void)state;(void)funcs;assert(!global_live);global_live=1;}
static void dpu_kms_global_obj_fini(struct dpu_kms *d) {(void)d;assert(global_live);global_live=0;}
static void atomic_set(int *n,int value) {*n=value;}
static int pm_runtime_resume_and_get(struct device *d) {(void)d;if(fail_at==1)return -EIO;assert(!pm_refs);pm_refs=1;return 0;}
static void pm_runtime_put_sync(struct device *d) {(void)d;assert(pm_refs==1);pm_refs=0;}
static int readl_relaxed(void *p) {(void)p;return 0x10010000;}
static const struct catalog *of_device_get_match_data(struct device *d) {(void)d;return fail_at==2?NULL:&catalog;}
static int _dpu_kms_mmu_init(struct dpu_kms *d) {if(fail_at==3)return -ENODEV;assert(!vm_live&&!mmu_live);vm_live=mmu_live=1;d->base.vm=&vm;return 0;}
static void drm_gpuvm_put(struct drm_gpuvm *v) {(void)v;assert(vm_live&&!mmu_live);vm_live=0;}
static void *qcom_ubwc_config_get_data(void) {return fail_at==4?ERR_PTR(-ENOMEM):fail_at==5?NULL:&mdss;}
static int dpu_rm_init(struct drm_device *d,int *rm,const struct catalog *c,void *m,void *io) {(void)d;(void)rm;(void)c;(void)m;(void)io;return fail_at==6?-ENOMEM:0;}
static struct hw_mdp *dpu_hw_mdptop_init(struct drm_device *d,void *config,void *io,int version) {(void)d;(void)config;(void)io;(void)version;return fail_at==7?ERR_PTR(-ENOMEM):&hw_mdp;}
static struct dpu_hw_vbif *dpu_hw_vbif_init(struct drm_device *d,const struct dpu_vbif_cfg *config,int io) {(void)d;(void)config;(void)io;return fail_at==8?ERR_PTR(-ENOMEM):&hw_vbif;}
static unsigned long dpu_kms_get_clk_rate(struct dpu_kms *d,const char *name) {(void)d;(void)name;return 0;}
static int dpu_core_perf_init(int *perf,void *config,unsigned long rate) {(void)perf;(void)config;(void)rate;return fail_at==9?-ENOMEM:0;}
static bool of_device_is_compatible(void *node,const char *compatible) {(void)node;(void)compatible;return false;}
static void *dpu_hw_intr_init(struct drm_device *d,void *io,const struct catalog *c) {(void)d;(void)io;(void)c;return fail_at==10?ERR_PTR(-ENOMEM):&intr;}
static int _dpu_kms_drm_obj_init(struct dpu_kms *d) {d->dev->count=fail_at==11?1:2;for(unsigned i=0;i<d->dev->count;i++)d->dev->crtcs[i].refresh=true;return fail_at==11?-ENOMEM:0;}
static void drm_self_refresh_helper_cleanup(struct drm_crtc *c) {assert(c->refresh);c->refresh=false;refresh_cleanups++;}
static void dpu_vbif_init_memtypes(struct dpu_kms *d) {assert(d->hw_vbif==&hw_vbif&&vm_live);}
static void _dpu_kms_mmu_destroy(struct dpu_kms *);
C
cat > "$work/dpu-cases.c" <<'C'
int main(void) {
 struct device dev={0};struct platform_device pdev={0};
 for(int failure=0;failure<=11;failure++){
  struct drm_device drm={.dev=&dev};struct dpu_kms dpu={.dev=&drm,.pdev=&pdev};
  fail_at=failure;pm_refs=global_live=vm_live=mmu_live=refresh_cleanups=0;
#ifdef LEGACY_HW_INIT
  int ret=dpu_kms_hw_init(&dpu.base);
#else
  int ret=dpu_kms_hw_init(&dpu);
#endif
  assert(pm_refs==0);
  if(failure){
   assert(ret<0&&!global_live&&!vm_live&&!mmu_live);
   assert(!dpu.hw_intr&&!dpu.hw_vbif&&!dpu.hw_mdp&&!dpu.base.vm);
   if(failure==11)assert(refresh_cleanups==1&&!drm.crtcs[0].refresh);
  }else{
   assert(!ret&&global_live&&vm_live&&mmu_live&&refresh_cleanups==0);
   _dpu_kms_hw_destroy(&dpu);assert(!global_live&&!vm_live&&!mmu_live&&refresh_cleanups==2);
   assert(!dpu.hw_intr&&!dpu.hw_vbif&&!dpu.hw_mdp&&!dpu.catalog&&!dpu.base.vm);
  }
 }
 puts("Actual DPU hardware initialization: all eleven failure sites, VM/block rollback and self-refresh teardown passed");return 0;
}
C
cat > "$work/drm-preamble.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define ERR_PTR(n) ((void *)(intptr_t)(n))
#define PTR_ERR(p) ((int)(intptr_t)(p))
#define IS_ERR(p) ((uintptr_t)(p)>=(uintptr_t)-4095)
#define UINT_MAX 0xffffffffU
#define GFP_KERNEL 0
#define DRM_DEV_ERROR(...) ((void)0)
struct device {void *drvdata;};
struct platform_device {struct device dev;};
struct drm_driver {int unused;};
struct drm_device {struct device *dev;struct msm_drm_private *dev_private;bool registered;int gem_lru_mutex;};
struct msm_drm_private {struct drm_device *dev;void *kms;int (*kms_init)(struct drm_device *);int objects,obj_lock;struct {int unbacked,pinned,willneed,dontneed;} lru;int fault_stall_lock;bool stall_enabled;};
struct component_ops {int (*bind)(struct device *,struct device *,void *);void (*unbind)(struct device *,struct device *,void *);};
#define container_of(p,t,m) ((t *)((char *)(p)-offsetof(t,m)))
#define to_platform_device(d) container_of(d,struct platform_device,dev)
#define platform_get_drvdata(p) ((struct msm_drm_private *)(p)->dev.drvdata)
#define dev_get_drvdata(d) ((struct msm_drm_private *)(d)->drvdata)
#define INIT_LIST_HEAD(p) (*(p)=0)
#define mutex_init(p) (*(p)=0)
#define spin_lock_init(p) (*(p)=0)
#define might_lock(p) ((void)(p))
static int failure;static bool allocated,bound,shrinker,kms_live,debug_live,unregistered;static int put_count,shutdowns;
static struct drm_device fixture_drm;static struct msm_drm_private fixture_priv;static struct platform_device pdev;
static bool drm_firmware_drivers_only(void) {return false;}
static struct drm_device *drm_dev_alloc(const struct drm_driver *drv,struct device *d) {(void)drv;if(failure==1)return ERR_PTR(-ENOMEM);allocated=true;fixture_drm.dev=d;return &fixture_drm;}
static void drm_dev_put(struct drm_device *d) {assert(allocated&&!bound&&!shrinker&&!kms_live&&!debug_live&&!d->registered&&!d->dev_private);allocated=false;put_count++;}
static void drm_gem_lru_init(int *lru) {*lru=0;}
static void fs_reclaim_acquire(int flags) {(void)flags;}
static void fs_reclaim_release(int flags) {(void)flags;}
static int drmm_mode_config_init(struct drm_device *d) {(void)d;return failure==2?-ENOMEM:0;}
static void dma_set_max_seg_size(struct device *d,unsigned size) {(void)d;(void)size;}
static int component_bind_all(struct device *dev,struct drm_device *d) {(void)dev;(void)d;if(failure==3)return -EIO;assert(!bound);bound=true;return 0;}
static void component_unbind_all(struct device *dev,struct drm_device *d) {(void)dev;(void)d;assert(bound&&!kms_live&&!shrinker);bound=false;}
static int gpu_bind(struct device *dev,struct device *master,void *d) {(void)master;(void)d;return component_bind_all(dev,&fixture_drm);}
static void gpu_unbind(struct device *dev,struct device *master,void *d) {(void)master;(void)d;component_unbind_all(dev,&fixture_drm);}
static int msm_gem_shrinker_init(struct drm_device *d) {(void)d;if(failure==4)return -ENOMEM;shrinker=true;return 0;}
static void msm_gem_shrinker_cleanup(struct drm_device *d) {(void)d;assert(shrinker);shrinker=false;}
static int msm_drm_kms_init(struct device *dev,const struct drm_driver *drv) {(void)dev;(void)drv;if(failure==5)return -EIO;assert(bound&&shrinker);kms_live=true;return 0;}
static void msm_drm_kms_uninit(struct device *dev) {(void)dev;assert(kms_live&&!fixture_drm.registered);kms_live=false;}
static int drm_dev_register(struct drm_device *d,unsigned flags) {(void)flags;if(failure==6)return -EIO;d->registered=true;return 0;}
static void drm_dev_unregister(struct drm_device *d) {assert(d->registered);d->registered=false;unregistered=true;}
static int msm_debugfs_late_init(struct drm_device *d) {(void)d;debug_live=true;return failure==7?-ENOMEM:0;}
static void msm_rd_debugfs_cleanup(struct msm_drm_private *p) {(void)p;debug_live=false;}
static void msm_drm_kms_unregister(struct device *d) {(void)d;assert(unregistered&&kms_live);shutdowns++;}
static void msm_drm_kms_post_init(struct device *d) {(void)d;assert(kms_live&&fixture_drm.registered);}
static int kms_marker(struct drm_device *d) {(void)d;return 0;}
C
cat > "$work/drm-cases.c" <<'C'
int main(void) {
 struct drm_driver drv={0};const struct component_ops gpu={gpu_bind,gpu_unbind};
 for(int with_kms=0;with_kms<2;with_kms++)for(int with_gpu=0;with_gpu<2;with_gpu++)for(int fail=0;fail<=7;fail++){
  if(!with_kms&&(fail==2||fail==5))continue;
  failure=fail;allocated=bound=shrinker=kms_live=debug_live=unregistered=false;put_count=shutdowns=0;
  memset(&fixture_drm,0,sizeof(fixture_drm));fixture_priv=(struct msm_drm_private){.kms=with_kms?&fixture_priv:NULL,.kms_init=with_kms?kms_marker:NULL};pdev.dev.drvdata=&fixture_priv;
  const struct component_ops *ops=with_gpu?&gpu:NULL;
  int ret=msm_drm_init(&pdev.dev,&drv,ops);
  if(fail)assert(ret<0);else{assert(!ret&&fixture_drm.registered);assert(!msm_drm_uninit(&pdev.dev,ops));}
  assert(!allocated&&!bound&&!shrinker&&!kms_live&&!debug_live&&!fixture_drm.registered);
  assert(put_count==(fail==1?0:1));
  assert(shutdowns==((fail==0||fail==7)&&with_kms?1:0));
 }
 printf("Actual DRM bind/init: component and GPU paths, all seven failure sites and successful unbind passed\n");return 0;
}
C
compile() {
    local tree=$1 mode=$2 output=$3 msm=$1/drivers/gpu/drm/msm extra=()
    cat "$work/$mode-preamble.c" > "$work/$output.c"
    if [[ $mode == dpu ]]; then
        local source=$msm/disp/dpu1/dpu_kms.c
        for function in _dpu_kms_mmu_destroy dpu_kms_self_refresh_cleanup; do extract "$source" "$function" true >> "$work/$output.c"; done
        for function in _dpu_kms_hw_destroy dpu_kms_hw_init; do extract "$source" "$function" >> "$work/$output.c"; done
        if grep -Fq 'dpu_kms_hw_init(struct msm_kms *kms)' "$source"; then extra=(-DLEGACY_HW_INIT=1); fi
    else
        for function in msm_drm_uninit msm_drm_init; do extract "$msm/msm_drv.c" "$function" >> "$work/$output.c"; done
    fi
    cat "$work/$mode-cases.c" >> "$work/$output.c"
    "${CC:-clang}" -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable -Wno-sign-compare \
        -fsanitize=undefined -fsanitize-undefined-trap-on-error "${extra[@]}" "$work/$output.c" -o "$work/$output"
}
for mode in dpu drm; do
    compile "$candidate" "$mode" "candidate-$mode"
    "$work/candidate-$mode"
    compile "$baseline" "$mode" "baseline-$mode"
    if "$work/baseline-$mode" > "$work/baseline-$mode.log" 2>&1; then code=0; else code=$?; fi
    [[ $code == 134 ]] || { printf 'Unmodified %s unwind control did not assert (status%s)\n' "$mode" "$code" >&2; cat "$work/baseline-$mode.log" >&2; exit 1; }
    printf 'Unmodified %s unwind assertion control refused\n' "$mode"
done
