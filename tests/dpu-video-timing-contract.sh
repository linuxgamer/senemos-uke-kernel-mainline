#!/usr/bin/env bash
# Execute actual video timing, lifecycle, IRQ and virtual kickoff functions on the host.
set -Eeuo pipefail
kernel=${1:?Pass the prepared native kernel source}
file=$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_encoder_phys_vid.c
encoder=$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_encoder.c
top=$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_hw_top.c
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
extract() {
    awk -v signature="$2" '
        $0 == signature { emit=1; found=1 }
        emit { print }
        emit && /^}/ { exit }
        END { if (!found) exit 1 }
    ' "$1"
}
cat > "$work/check.cpp" <<'CPP'
#include <array>
#include <cassert>
#include <cerrno>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>
using u32=uint32_t; using u8=uint8_t;
enum role {ENC_ROLE_SOLO,ENC_ROLE_MASTER,ENC_ROLE_SLAVE};
CPP
if grep -Fq 'retire_disable_error' "$file";then
    printf '#define UKE_RETIRE_PROOF 1\n' >> "$work/check.cpp"
fi
{
sed -n '/^enum dpu_enc_enable_state {/,/^};/p' \
    "$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_encoder_phys.h"
for type in dpu_intf dpu_intf_type dpu_intf_mode; do
    sed -n "/^enum $type {/,/^};/p" "$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_hw_mdss.h"
done
cat <<'CPP'
enum {INTR_IDX_VSYNC,INTR_IDX_UNDERRUN,CTL_0=0,KICKOFF_TIMEOUT_MS=84,
      CDM_CDWN_OUTPUT_HDMI=0};
struct dpu_mdss_version {int core_major_ver;};
struct dpu_mdss_cfg {const dpu_mdss_version *mdss_ver;};
static const dpu_mdss_version modern{10},legacy{4};
static const dpu_mdss_cfg dpu_sm7675_cfg{&modern},other_catalog{&modern},old_catalog{&legacy};
struct dpu_kms {const dpu_mdss_cfg *catalog;int base;};
struct drm_device {};
struct drm_encoder {drm_device *dev;};
struct dpu_hw_intf_status {bool is_en;};
struct dpu_hw_intf;
struct intf_ops {
    void (*enable_timing)(dpu_hw_intf *,u8);
    void (*get_status)(dpu_hw_intf *,dpu_hw_intf_status *);
    void (*avr_trigger)(dpu_hw_intf *){};
};
struct dpu_hw_intf {dpu_intf idx;intf_ops ops;bool enabled;
    bool stick_on{};int status_reads{};std::vector<bool> status_sequence{};};
struct split_pipe_cfg {bool en;dpu_intf_mode mode{};dpu_intf intf{};bool split_flush_en{};};
struct dpu_hw_blk_reg_map {std::array<u32,256> regs{};};
struct dpu_hw_mdp;
struct mdp_ops {void (*setup_split_pipe)(dpu_hw_mdp *,split_pipe_cfg *);};
struct dpu_hw_mdp {dpu_hw_blk_reg_map hw;mdp_ops ops;};
struct msm_display_info {dpu_intf_type intf_type;u32 num_of_h_tiles;
    u32 h_tile_instance[2];bool is_cmd_mode;};
struct dpu_hw_ctl;
struct ctl_ops {
    void (*update_pending_flush_intf)(dpu_hw_ctl *,int);
    void (*update_pending_flush_merge_3d)(dpu_hw_ctl *,int);
    void (*update_pending_flush_cdm)(dpu_hw_ctl *,int);
    void (*update_pending_flush_periph)(dpu_hw_ctl *,int);
    u32 (*get_flush_register)(dpu_hw_ctl *);
    u32 (*get_pending_flush)(dpu_hw_ctl *);
    void (*trigger_flush)(dpu_hw_ctl *){};
};
struct dpu_hw_ctl {int idx;ctl_ops ops;u32 pending,live;};
struct dpu_hw_merge_3d {int idx;};
struct dpu_hw_pingpong {dpu_hw_merge_3d *merge_3d;};
struct dpu_hw_cdm {int idx;};
struct dpu_encoder_phys;
struct physical_ops {bool (*needs_single_flush)(dpu_encoder_phys *);
    void (*handle_post_kickoff)(dpu_encoder_phys *);};
struct dpu_encoder_phys {
    role split_role; dpu_enc_enable_state enable_state; int *enc_spinlock;
    struct dpu_kms *dpu_kms;dpu_hw_intf *hw_intf;dpu_hw_ctl *hw_ctl;
    dpu_hw_pingpong *hw_pp;dpu_hw_cdm *hw_cdm;
    drm_encoder *parent;physical_ops ops;
    int pending_kickoff_cnt,pending_kickoff_wq,vblank_ctl_lock,vblank_refcount;
    unsigned int irq[2];int underrun_cnt;
    dpu_hw_mdp *hw_mdptop{};dpu_intf_mode intf_mode{INTF_MODE_NONE};
    int retire_disable_error{};
};
struct dpu_encoder_virt {
    drm_encoder base;dpu_encoder_phys *phys_encs[2];unsigned int num_phys_encs;
    int enc_spinlock;unsigned long frame_busy_mask[1];dpu_encoder_phys *cur_master;
    dpu_encoder_phys *cur_slave{};msm_display_info disp_info{};
    bool avr_enabled{};
};
struct dpu_encoder_wait_info {int *wq,*atomic_cnt;unsigned int timeout_ms;};
struct msm_format {};
static int setup[INTF_MAX],cleanup[INTF_MAX],wait_calls,irq_registers,irq_unregisters;
static bool irq_timeout;
static int cleanup_error;
static bool root_uke=true,root_sm7675=true;
static int error_count;
static std::vector<int> irq_results;
static std::vector<std::string> events;
static std::vector<std::pair<u32,u32>> register_writes;
static bool of_machine_is_compatible(const char *name) {
    if(std::string(name)=="xiaomi,uke")return root_uke;
    if(std::string(name)=="qcom,sm7675")return root_sm7675;
    assert(false);return false;
}
static void register_write(dpu_hw_blk_reg_map *hw,u32 offset,u32 value) {
    hw->regs.at(offset/4)=value;register_writes.emplace_back(offset,value);
}
#define BIT(n) (1U<<(n))
#define DPU_REG_WRITE(c,offset,value) register_write(c,offset,value)
#define SSPP_SPARE 0x028
#define SPLIT_DISPLAY_EN 0x2f4
#define SPLIT_DISPLAY_UPPER_PIPE_CTRL 0x2f8
#define SPLIT_DISPLAY_LOWER_PIPE_CTRL 0x3f0
#define FLD_SPLIT_DISPLAY_CMD BIT(1)
#define FLD_INTF_1_SW_TRG_MUX BIT(4)
#define FLD_INTF_2_SW_TRG_MUX BIT(8)
#define WARN_ON(c) (c)
#define DPU_DEBUG_VIDENC(...) ((void)0)
#define DPU_DEBUG_ENC(...) ((void)0)
#define DPU_ERROR(...) (++error_count)
#define DRM_DEBUG_VBL(...) ((void)0)
#define DRM_ERROR(...) ((void)0)
#define DPU_ERROR_VIDENC(...) ((void)0)
#define DRMID(...) 0
#define trace_dpu_enc_phys_vid_post_kickoff(...) ((void)0)
#define trace_dpu_enc_kickoff(...) ((void)0)
#define DPU_ATRACE_BEGIN(...) ((void)0)
#define DPU_ATRACE_END(...) ((void)0)
#define spin_lock_irqsave(lock,flags) do {(void)(lock);(flags)=0;}while(0)
#define spin_unlock_irqrestore(lock,flags) do {(void)(lock);(void)(flags);}while(0)
#define mutex_lock(lock) ((void)(lock))
#define mutex_unlock(lock) ((void)(lock))
#define atomic_set(counter,value) (*(counter)=(value))
#define wait_event_timeout(wq,condition,ms) ((void)(wq),(void)(ms),(condition)?1:0)
static unsigned int msecs_to_jiffies(unsigned int ms) {return ms;}
static void timing(dpu_hw_intf *intf,u8 enabled) {
    if(enabled || !intf->stick_on)intf->enabled=enabled!=0;
    events.emplace_back("timer"+std::to_string(intf->idx-INTF_0)+"="+std::to_string(enabled));
}
static void status(dpu_hw_intf *intf,dpu_hw_intf_status *out) {
    ++intf->status_reads;
    if(!intf->status_sequence.empty()) {
        out->is_en=intf->status_sequence.front();
        intf->status_sequence.erase(intf->status_sequence.begin());
    } else out->is_en=intf->enabled;
}
static void flush_mask(dpu_hw_ctl *ctl,int idx) {ctl->pending|=1U<<(idx-INTF_0);}
static u32 get_live(dpu_hw_ctl *ctl) {return ctl->live;}
static u32 get_pending(dpu_hw_ctl *ctl) {return ctl->pending;}
static void trigger_flush(dpu_hw_ctl *) {}
static void dpu_encoder_phys_vid_setup_timing_engine(dpu_encoder_phys *p) {++setup[p->hw_intf->idx];}
static void dpu_encoder_helper_phys_setup_cdm(dpu_encoder_phys *,const msm_format *,int) {}
static u32 dpu_encoder_get_drm_fmt(dpu_encoder_phys *) {return 0;}
static const msm_format *mdp_get_format(int *,u32,int) {static msm_format fmt;return &fmt;}
static u32 dpu_encoder_helper_get_3d_blend_mode(dpu_encoder_phys *) {return 0;}
static bool dpu_encoder_needs_periph_flush(dpu_encoder_phys *) {return false;}
static int dpu_encoder_phys_inc_pending(dpu_encoder_phys *p) {return ++p->pending_kickoff_cnt;}
static int dpu_encoder_helper_wait_for_irq(dpu_encoder_phys *p,unsigned int,
                                         void (*)(void *),dpu_encoder_wait_info *info) {
    ++wait_calls;assert(info->atomic_cnt==&p->pending_kickoff_cnt);
    if(!irq_results.empty()) {
        const int ret=irq_results.front();irq_results.erase(irq_results.begin());
        if(ret)return ret;
    }
    if(irq_timeout)return -ETIMEDOUT;
    *info->atomic_cnt=0;return 0;
}
static void dpu_encoder_helper_report_irq_timeout(dpu_encoder_phys *,int) {}
static void dpu_encoder_phys_vid_vblank_irq(void *) {}
static int dpu_core_irq_register_callback(dpu_kms *,unsigned int,void (*)(void *),void *) {
    ++irq_registers;return 0;
}
static int dpu_core_irq_unregister_callback(dpu_kms *,unsigned int) {++irq_unregisters;return 0;}
static void dpu_encoder_helper_phys_cleanup(dpu_encoder_phys *p) {++cleanup[p->hw_intf->idx];p->retire_disable_error=cleanup_error;}
static void set_bit(unsigned int n,unsigned long *mask) {*mask|=1UL<<n;}
static void _dpu_encoder_trigger_flush(drm_encoder *,dpu_encoder_phys *p,u32 extra) {
    p->hw_ctl->pending|=extra;
    ++p->pending_kickoff_cnt;
    events.emplace_back("flush"+std::to_string(p->hw_intf->idx-INTF_0));
    p->hw_ctl->live=0; // bounded model of a hardware-accepted flush, not a hardware claim
}
static void _dpu_encoder_trigger_start(dpu_encoder_phys *p) {
    assert(p->split_role!=ENC_ROLE_SLAVE);
    events.emplace_back("start"+std::to_string(p->hw_intf->idx-INTF_0));
}
static dpu_encoder_virt *to_dpu_encoder_virt(drm_encoder *p) {
    return reinterpret_cast<dpu_encoder_virt *>(p);
}
CPP
} >> "$work/check.cpp"
{
    extract "$top" 'static void dpu_hw_setup_split_pipe(struct dpu_hw_mdp *mdp,'
    extract "$encoder" 'static bool dpu_encoder_uke_split_flush(struct dpu_encoder_phys *phys_enc)'
    extract "$encoder" 'void dpu_encoder_helper_split_config('
    extract "$encoder" 'void dpu_encoder_helper_split_flush_cleanup(struct dpu_encoder_phys *phys_enc,'
    for signature in \
        'static bool dpu_encoder_phys_vid_is_master(' \
        'static bool dpu_encoder_phys_vid_needs_single_flush(' \
        'static int dpu_encoder_phys_vid_control_vblank_irq(' \
        'static void dpu_encoder_phys_vid_enable(struct dpu_encoder_phys *phys_enc)' \
        'static int dpu_encoder_phys_vid_wait_for_tx_complete(' \
        'static int dpu_encoder_phys_vid_wait_for_commit_done(' \
        'static void dpu_encoder_phys_vid_disable(struct dpu_encoder_phys *phys_enc)' \
        'static void dpu_encoder_phys_vid_handle_post_kickoff('; do
        extract "$file" "$signature"
    done
    extract "$encoder" 'static void _dpu_encoder_kickoff_phys(struct dpu_encoder_virt *dpu_enc)'
    extract "$encoder" 'void dpu_encoder_kickoff(struct drm_encoder *drm_enc)'
    cat <<'CPP'
static void split_contract_tests() {
    dpu_kms kms{&dpu_sm7675_cfg,0},different_kms{&dpu_sm7675_cfg,0};
    drm_device device;
    dpu_encoder_virt virt{{&device},{},2,0,{0},nullptr},other{};
    dpu_hw_ctl ctl{},other_ctl{};
    dpu_hw_mdp mdp{{},{dpu_hw_setup_split_pipe}},other_mdp{};
    dpu_hw_intf intfs[2]{{INTF_1,{timing,status},false},{INTF_2,{timing,status},false}};
    dpu_encoder_phys p[2]{};
    virt.cur_master=&p[0];virt.cur_slave=&p[1];virt.disp_info={INTF_DSI,2,{0,1},false};
    for(int i=0;i<2;i++) {
        p[i].parent=&virt.base;p[i].dpu_kms=&kms;p[i].hw_ctl=&ctl;
        p[i].hw_mdptop=&mdp;p[i].hw_intf=&intfs[i];p[i].intf_mode=INTF_MODE_VIDEO;
        p[i].split_role=i ? ENC_ROLE_SLAVE:ENC_ROLE_MASTER;
        p[i].ops.needs_single_flush=dpu_encoder_phys_vid_needs_single_flush;
        virt.phys_encs[i]=&p[i];
    }
    assert(dpu_encoder_uke_split_flush(&p[0]));
    assert(!dpu_encoder_uke_split_flush(&p[1]));
    // Each rejected qualification must preserve the old shared setter behavior.
    auto reject=[&] {
        assert(!dpu_encoder_uke_split_flush(&p[0]));
        mdp.hw.regs.fill(0);register_writes.clear();
        if(p[0].dpu_kms)dpu_encoder_helper_split_config(&p[0],INTF_1);
        assert(mdp.hw.regs[SSPP_SPARE/4]==0);
        register_writes.clear();
        dpu_encoder_helper_split_flush_cleanup(&p[0],0);
        assert(register_writes.empty());
    };
#define REJECT(field,value) do {const auto saved=(field);(field)=(value);reject();(field)=saved;}while(0)
    REJECT(p[0].parent,nullptr);REJECT(p[0].dpu_kms,nullptr);
    REJECT(kms.catalog,&other_catalog);REJECT(root_uke,false);REJECT(root_sm7675,false);
    REJECT(p[0].split_role,ENC_ROLE_SOLO);REJECT(p[0].split_role,ENC_ROLE_SLAVE);
    REJECT(p[0].intf_mode,INTF_MODE_CMD);REJECT(p[0].hw_intf,nullptr);
    REJECT(intfs[0].idx,INTF_2);REJECT(p[0].hw_ctl,nullptr);
    REJECT(p[0].hw_mdptop,nullptr);REJECT(mdp.ops.setup_split_pipe,nullptr);
    REJECT(virt.disp_info.intf_type,INTF_DP);REJECT(virt.disp_info.is_cmd_mode,true);
    REJECT(virt.disp_info.num_of_h_tiles,1);REJECT(virt.disp_info.h_tile_instance[0],1);
    REJECT(virt.disp_info.h_tile_instance[1],0);REJECT(virt.num_phys_encs,1);
    REJECT(virt.cur_master,nullptr);REJECT(virt.phys_encs[0],&p[1]);
    REJECT(virt.phys_encs[1],&p[0]);REJECT(virt.cur_slave,nullptr);
    REJECT(p[1].parent,&other.base);REJECT(p[1].split_role,ENC_ROLE_SOLO);
    REJECT(p[1].intf_mode,INTF_MODE_CMD);REJECT(p[1].dpu_kms,&different_kms);
    REJECT(p[1].hw_mdptop,&other_mdp);REJECT(p[1].hw_ctl,&other_ctl);
    REJECT(p[1].hw_intf,nullptr);REJECT(intfs[1].idx,INTF_1);
#undef REJECT
    // Compare every setter word: only SSPP_SPARE differs from modern policy.
    root_uke=false;dpu_encoder_helper_split_config(&p[0],INTF_1);
    const auto baseline=mdp.hw.regs;root_uke=true;
    dpu_encoder_helper_split_config(&p[0],INTF_1);
    for(unsigned i=0;i<baseline.size();i++)
        assert(mdp.hw.regs[i]==(i==SSPP_SPARE/4 ? 1U:baseline[i]));
    const auto enabled=mdp.hw.regs;
    auto retain=[&](int ret) {
        register_writes.clear();const int errors=error_count;
        dpu_encoder_helper_split_flush_cleanup(&p[0],ret);
        assert(register_writes.empty() && mdp.hw.regs==enabled && error_count==errors+1);
    };
    retain(-ETIMEDOUT);
    intfs[0].ops.get_status=nullptr;retain(0);intfs[0].ops.get_status=status;
    intfs[1].ops.get_status=nullptr;retain(0);intfs[1].ops.get_status=status;
    intfs[0].enabled=true;retain(0);intfs[0].enabled=false;
    intfs[1].enabled=true;retain(0);intfs[1].enabled=false;
    const int master_reads=intfs[0].status_reads,slave_reads=intfs[1].status_reads;
    dpu_encoder_helper_split_flush_cleanup(&p[0],0);
    assert(mdp.hw.regs==baseline);
    assert(intfs[0].status_reads==master_reads+1 && intfs[1].status_reads==slave_reads+1);
    dpu_encoder_helper_split_config(&p[0],INTF_1);assert(mdp.hw.regs==enabled);
    register_writes.clear();dpu_encoder_helper_split_flush_cleanup(&p[1],0);
    assert(register_writes.empty() && mdp.hw.regs==enabled);
    // Exercise the real disable caller and its final wait/status provenance.
    auto disable=[&](std::vector<int> waits,std::vector<bool> states,bool clear) {
        irq_timeout=false;irq_results=std::move(waits);p[0].enable_state=DPU_ENC_ENABLED;
        intfs[0].status_sequence=std::move(states);intfs[0].enabled=true;
        dpu_encoder_helper_split_config(&p[0],INTF_1);
        dpu_encoder_phys_vid_disable(&p[0]);
        assert(irq_results.empty() && intfs[0].status_sequence.empty());
        assert(mdp.hw.regs[SSPP_SPARE/4]==(clear ? 0U:1U));
    };
    disable({0},{false,false},true);
    disable({-ETIMEDOUT},{false},false);
    disable({0,-ETIMEDOUT},{true},false);
    disable({-ETIMEDOUT,0},{true,false},true);
    disable({0,0},{true,true},false);
    disable({0},{false,true},false);
    intfs[1].enabled=true;disable({0},{false,false},false);intfs[1].enabled=false;
#ifdef UKE_RETIRE_PROOF
    for(int error:{0,-EIO}) {
        cleanup_error=error;disable({0},{false,false},true);
        assert(p[0].enable_state==DPU_ENC_DISABLED && p[0].retire_disable_error==error);
    }
    cleanup_error=0;intfs[0].ops.get_status=nullptr;
    p[0].enable_state=DPU_ENC_ENABLED;intfs[0].enabled=true;
    dpu_encoder_phys_vid_disable(&p[0]);assert(p[0].retire_disable_error==-EOPNOTSUPP);
    intfs[0].ops.get_status=status;intfs[0].stick_on=true;
    p[0].enable_state=DPU_ENC_ENABLED;intfs[0].enabled=true;
    dpu_encoder_phys_vid_disable(&p[0]);assert(p[0].retire_disable_error==-EBUSY);
    intfs[0].stick_on=false;
#endif
}
int main() {
    for(const auto *catalog : {&dpu_sm7675_cfg,&other_catalog})
    for(const auto split : {ENC_ROLE_SOLO,ENC_ROLE_MASTER,ENC_ROLE_SLAVE})
    for(const auto initial : {DPU_ENC_DISABLING,DPU_ENC_DISABLED,DPU_ENC_ENABLING,
                             DPU_ENC_ENABLED,DPU_ENC_ERR_NEEDS_HW_RESET}) {
        dpu_kms kms{catalog,0};
        dpu_hw_intf intf{INTF_1,{timing,status},false};
        int lock=0;
        dpu_encoder_phys p{};
        p.split_role=split;p.enable_state=initial;p.enc_spinlock=&lock;
        p.dpu_kms=&kms;p.hw_intf=&intf;
        assert(dpu_encoder_phys_vid_is_master(&p)==(split!=ENC_ROLE_SLAVE));
        events.clear();
        const bool expected=initial==DPU_ENC_ENABLING &&
            (catalog!=&dpu_sm7675_cfg || split!=ENC_ROLE_SLAVE);
        dpu_encoder_phys_vid_handle_post_kickoff(&p);
        assert(events.size()==unsigned(expected) && intf.enabled==expected);
        assert(p.enable_state==(initial==DPU_ENC_ENABLING ? DPU_ENC_ENABLED:initial));
        dpu_encoder_phys_vid_handle_post_kickoff(&p);
        assert(events.size()==unsigned(expected));
        p.enable_state=DPU_ENC_ENABLING;events.clear();intf.enabled=false;
        dpu_encoder_phys_vid_handle_post_kickoff(&p);
        assert(p.enable_state==DPU_ENC_ENABLED);
        assert(intf.enabled==(catalog!=&dpu_sm7675_cfg || split!=ENC_ROLE_SLAVE));
    }
    for(const auto *catalog : {&dpu_sm7675_cfg,&other_catalog,&old_catalog}) {
        events.clear();wait_calls=irq_registers=irq_unregisters=0;irq_timeout=false;
        for(auto &v:setup)v=0;
        for(auto &v:cleanup)v=0;
        dpu_kms kms{catalog,0};drm_device device;
        dpu_hw_ctl ctl{0,{flush_mask,nullptr,nullptr,nullptr,get_live,get_pending,trigger_flush},0,0};
        dpu_hw_intf intfs[2]{{INTF_1,{timing,status},false},{INTF_2,{timing,status},false}};
        dpu_hw_mdp mdp{{},{dpu_hw_setup_split_pipe}};
        dpu_hw_pingpong pp{};
        dpu_encoder_virt virt{{&device},{},2,0,{0},nullptr};
        dpu_encoder_phys p[2]{};
        virt.cur_slave=&p[1];virt.disp_info={INTF_DSI,2,{0,1},false};
        for(int i=0;i<2;i++) {
            p[i].split_role=i ? ENC_ROLE_SLAVE:ENC_ROLE_MASTER;
            p[i].enable_state=DPU_ENC_DISABLED;p[i].enc_spinlock=&virt.enc_spinlock;
            p[i].dpu_kms=&kms;p[i].hw_intf=&intfs[i];p[i].hw_ctl=&ctl;p[i].hw_pp=&pp;
            p[i].parent=&virt.base;p[i].ops.needs_single_flush=dpu_encoder_phys_vid_needs_single_flush;
            p[i].hw_mdptop=&mdp;p[i].intf_mode=INTF_MODE_VIDEO;
            p[i].ops.handle_post_kickoff=dpu_encoder_phys_vid_handle_post_kickoff;
            virt.phys_encs[i]=&p[i];
        }
        virt.cur_master=&p[0];
        assert(dpu_encoder_phys_vid_control_vblank_irq(&p[1],true)==0 && !p[1].vblank_refcount);
        assert(dpu_encoder_phys_vid_control_vblank_irq(&p[0],true)==0 && p[0].vblank_refcount==1);
        assert(irq_registers==1);
        assert(dpu_encoder_phys_vid_control_vblank_irq(&p[1],false)==0 && !irq_unregisters);
        for(int cycle=0;cycle<2;cycle++) {
            ctl.pending=0;events.clear();virt.frame_busy_mask[0]=0;
            // Actual virtual-enable caller orders slave setup before master setup.
            dpu_encoder_phys_vid_enable(&p[1]);dpu_encoder_phys_vid_enable(&p[0]);
            assert(mdp.hw.regs[SSPP_SPARE/4]==(catalog==&other_catalog ? 0U:1U));
            assert(setup[INTF_1]==cycle+1 && setup[INTF_2]==cycle+1);
            assert(p[0].enable_state==DPU_ENC_ENABLING && p[1].enable_state==DPU_ENC_ENABLING);
            assert(!intfs[0].enabled && !intfs[1].enabled);
            assert(ctl.pending==(catalog==&old_catalog ? 2U:6U));
            const int master_pending=p[0].pending_kickoff_cnt,slave_pending=p[1].pending_kickoff_cnt;
            dpu_encoder_kickoff(&virt.base);
            assert(p[0].pending_kickoff_cnt==master_pending+1);
            assert(p[1].pending_kickoff_cnt==slave_pending+(catalog==&old_catalog ? 0:1));
            auto expected_flush=catalog!=&other_catalog ?
                std::vector<std::string>{"flush1","start1"}:
                std::vector<std::string>{"flush1","flush2","start1"};
            expected_flush.emplace_back("timer1=1");
            if(catalog!=&dpu_sm7675_cfg)expected_flush.emplace_back("timer2=1");
            assert(events==expected_flush && virt.frame_busy_mask[0]==1);
            assert(p[0].enable_state==DPU_ENC_ENABLED && p[1].enable_state==DPU_ENC_ENABLED);
            assert(intfs[0].enabled);
            assert(intfs[1].enabled==(catalog!=&dpu_sm7675_cfg));
            const auto count=events.size();
            dpu_encoder_phys_vid_handle_post_kickoff(&p[0]);
            dpu_encoder_phys_vid_handle_post_kickoff(&p[1]);
            assert(events.size()==count);
            // Slave TX wait has no vblank dependency, but its CTL commit wait is retained.
            const int before_wait=wait_calls;
            assert(dpu_encoder_phys_vid_wait_for_tx_complete(&p[1])==0 && wait_calls==before_wait);
            assert(dpu_encoder_phys_vid_wait_for_commit_done(&p[1])==0);
            ctl.live=1;
            assert(dpu_encoder_phys_vid_wait_for_commit_done(&p[1])==-ETIMEDOUT);
            ctl.live=0;
            assert(dpu_encoder_phys_vid_wait_for_tx_complete(&p[0])==0 && wait_calls==before_wait+1);
            dpu_encoder_phys_vid_disable(&p[0]);
            assert(mdp.hw.regs[SSPP_SPARE/4]==(catalog==&old_catalog ? 1U:0U));
            const int after_master=wait_calls;
            dpu_encoder_phys_vid_disable(&p[1]);
            assert(wait_calls==after_master && !intfs[0].enabled && !intfs[1].enabled);
            assert(cleanup[INTF_1]==cycle+1 && cleanup[INTF_2]==cycle+1);
            assert(p[0].enable_state==DPU_ENC_DISABLED && p[1].enable_state==DPU_ENC_DISABLED);
        }
        assert(dpu_encoder_phys_vid_control_vblank_irq(&p[0],false)==0 && !p[0].vblank_refcount);
        assert(irq_unregisters==1);
        if(catalog==&dpu_sm7675_cfg) {
            // The gate deliberately does not clear a previously inherited slave EN1.
            p[1].enable_state=DPU_ENC_ENABLING;intfs[1].enabled=true;
            const auto before=events.size();
            dpu_encoder_phys_vid_handle_post_kickoff(&p[1]);
            assert(p[1].enable_state==DPU_ENC_ENABLED && intfs[1].enabled && events.size()==before);
            dpu_encoder_phys_vid_disable(&p[1]);
            assert(!intfs[1].enabled && p[1].enable_state==DPU_ENC_DISABLED);
        }
        // Master disable IRQ timeout still cleans up and restores DISABLED, as upstream.
        dpu_encoder_phys_vid_enable(&p[0]);dpu_encoder_phys_vid_handle_post_kickoff(&p[0]);
        irq_timeout=true;dpu_encoder_phys_vid_disable(&p[0]);
        assert(p[0].enable_state==DPU_ENC_DISABLED && !intfs[0].enabled && !p[0].pending_kickoff_cnt);
        assert(mdp.hw.regs[SSPP_SPARE/4]==(catalog==&other_catalog ? 0U:1U));
    }
    split_contract_tests();
}
CPP
} >> "$work/check.cpp"
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror \
    -fsanitize=undefined -fsanitize-undefined-trap-on-error \
    "$work/check.cpp" -o "$work/check"
"$work/check"
printf 'Actual video timing/lifecycle/IRQ and virtual kickoff: scoped shared-CTL flush with both counters, unrelated modern two-flush, legacy path, re-enable, cleanup and master timeout passed\n'
