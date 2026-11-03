#!/usr/bin/env bash
# Host fault fixture for functions extracted from the prepared kernel.
set -euo pipefail
kernel=${1:?Pass prepared kernel tree}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
source=$kernel/sound/soc/qcom/qdsp6/q6apm.c
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cstdint>
#include <cstring>
#include <cerrno>
using u32=uint32_t;
#define __free(x)
#define IS_ERR(p) ((intptr_t)(p)<0 && (intptr_t)(p)>-4096)
#define PTR_ERR(p) ((intptr_t)(p))
#define READ_ONCE(x) (x)
#define WRITE_ONCE(x,y) ((x)=(y))
#define ATOMIC_INIT(x) x
using atomic_t=unsigned;
static unsigned atomic_inc_return(atomic_t *p){return ++*p;}
struct mutex{int depth=0;};
static void mutex_init(mutex*){}
static void mutex_lock(mutex *m){assert(m->depth==0);m->depth++;}
static void mutex_unlock(mutex *m){assert(m->depth==1);m->depth--;}
#define spin_lock_init(p) mutex_init(p)
#define spin_lock_irqsave(p,f) ((f)=0,mutex_lock(p))
#define spin_unlock_irqrestore(p,f) ((void)(f),mutex_unlock(p))
#define DEFINE_MUTEX(x) mutex x
struct device{void *data=nullptr;void *of_node=nullptr;};
struct gpr_device_t{device dev;struct {void *callback=nullptr;}svc;};
struct gpr_hdr{u32 token=0,opcode=0;};
struct gpr_pkt{gpr_hdr hdr;};
struct gpr_resp_pkt{gpr_hdr hdr;void *payload;int payload_size;};
struct gpr_ibasic_rsp_result_t{u32 opcode,status;};
struct q6apm{device *dev{};gpr_device_t *gdev{};mutex lock,state_lock,cmd_lock;
 bool removing=false;
 int wait=0,widget_list=0,graph_idr=0,graph_info_idr=0,sub_graphs_idr=0,containers_idr=0,modules_idr=0;
 u32 state=0,state_token=0;gpr_ibasic_rsp_result_t result{};};
static q6apm *g_apm;
static DEFINE_MUTEX(g_apm_lock);
static atomic_t apm_state_token=ATOMIC_INIT(0);
constexpr u32 APM_CMD_GET_SPF_STATE=0x01001021,APM_CMD_RSP_GET_SPF_STATE=0x02001007;
constexpr u32 GPR_BASIC_RSP_RESULT=0x02001005;
static int mode,requests,registrations,depopulations,unregistrations,wakes;
static bool allocation_fail;
static gpr_pkt packet;
static u32 old_token;
static gpr_pkt *audioreach_alloc_apm_cmd_pkt(int,u32,u32){return allocation_fail?reinterpret_cast<gpr_pkt*>(-ENOMEM):&packet;}
static int state_response(q6apm *apm,const gpr_resp_pkt *data){
 auto *result=static_cast<gpr_ibasic_rsp_result_t*>(data->payload);
 const auto *hdr=&data->hdr;
 unsigned long flags;
 (void)flags;
 switch(hdr->opcode){
CPP
awk '/case APM_CMD_RSP_GET_SPF_STATE:/ {emit=1} emit && /case APM_CMD_SHARED_MEM_MAP_REGIONS:/ {exit} emit {print}' "$source" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
 default: return -EINVAL;
 } break;
 default: return -EINVAL;
 } return 0;
}
static int q6apm_send_cmd_sync(q6apm *apm,const gpr_pkt *pkt,u32){
 requests++;assert(g_apm_lock.depth==1);
 if(mode==-EIO||mode==-ETIMEDOUT)return mode;
 u32 state=mode==2?2:mode==0?0:1;
 gpr_resp_pkt response{{pkt->hdr.token,APM_CMD_RSP_GET_SPF_STATE},&state,int(sizeof(state))};
 gpr_ibasic_rsp_result_t basic{APM_CMD_GET_SPF_STATE,7};
 if(mode==3)response.hdr.token=old_token;
 if(mode==4)response.payload_size=3;
 if(mode==5)response.payload=nullptr;
 if(mode==6)response.hdr.token=0;
 if(mode>=7){response.hdr.opcode=GPR_BASIC_RSP_RESULT;response.payload=&basic;response.payload_size=sizeof(basic);}
 if(mode==8)response.hdr.token=old_token;
 if(mode==9)response.payload=nullptr;
 if(mode==10)response.payload_size=7;
 if(mode==11)basic.status=0;
 if(mode==12)response.hdr.token=0;
 if(mode==13)basic.opcode=0xdead;
 old_token=pkt->hdr.token;int before=wakes;
 int ret=state_response(apm,&response);
 return ret?ret:wakes==before?-ETIMEDOUT:apm->result.status?-EINVAL:0;
}
static q6apm *dev_get_drvdata(device *d){return static_cast<q6apm*>(d->data);}
static void dev_set_drvdata(device *d,void *v){d->data=v;}
constexpr int GFP_KERNEL=0;
static q6apm slots[2];static int next_slot,register_result,populate_result;
static q6apm *devm_kzalloc(device*,size_t,int){if(allocation_fail)return nullptr;assert(next_slot<2);return &slots[next_slot++];}
static void INIT_LIST_HEAD(int*){}
static void idr_init(int*){}
static void init_waitqueue_head(int*){}
static int q6apm_audio_component;
static int snd_soc_register_component(device*,int*,void*,int){registrations++;return register_result;}
static void snd_soc_unregister_component(device*){unregistrations++;}
static void q6apm_purge_failed_graphs(q6apm*){}
static void gpr_quiesce_service(gpr_device_t *gdev){gdev->svc.callback=nullptr;}
static int of_platform_populate(void*,void*,void*,device*){return populate_result;}
static void of_platform_depopulate(device*){depopulations++;}
#define dev_err(...) ((void)0)
#define wake_up(p) (++wakes)
CPP
# wake_up is needed in the extracted response body above.
sed -i '/static int state_response/i #define wake_up(p) (++wakes)' "$work/check.cpp"
awk '/^(static int q6apm_get_apm_state|bool q6apm_is_adsp_ready|static int apm_probe|static void apm_remove)\(/ {emit=1}
 emit {print} emit && /^}/ {emit=0}' "$source" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
int main(){
 (void)atomic_inc_return;(void)mutex_lock;(void)mutex_unlock;(void)apm_state_token;(void)dev_get_drvdata;
 gpr_device_t first{},second{};
 register_result=-EIO;assert(apm_probe(&first)==-EIO&&!g_apm&&requests==0&&registrations==1);
 next_slot=0;register_result=0;populate_result=-EINVAL;
 assert(apm_probe(&first)==-EINVAL&&!g_apm&&depopulations==1&&unregistrations==1);
 next_slot=0;populate_result=0;assert(apm_probe(&first)==0&&g_apm&&requests==0);
 assert(!q6apm_is_adsp_ready()&&requests==0);
 first.svc.callback=&first;mode=1;assert(q6apm_is_adsp_ready()&&wakes==1);
 const auto first_token=old_token;
 int before=wakes;mode=7;assert(!q6apm_is_adsp_ready()&&wakes==before+1&&g_apm->result.status==7);
 for(int value:{8,9,10,11,12,13}){before=wakes;mode=value;assert(!q6apm_is_adsp_ready()&&wakes==before);}
 for(int value:{0,2,3,4,5,6,-EIO,-ETIMEDOUT}){mode=value;assert(!q6apm_is_adsp_ready());}
 assert(old_token!=first_token);
 allocation_fail=true;assert(!q6apm_is_adsp_ready());allocation_fail=false;
 mode=1;assert(q6apm_is_adsp_ready());
 assert(apm_probe(&second)==-EBUSY&&g_apm==first.dev.data);
 apm_remove(&second);assert(g_apm==first.dev.data);
 apm_remove(&first);assert(!g_apm&&!q6apm_is_adsp_ready()&&!first.svc.callback&&static_cast<q6apm*>(first.dev.data)->removing);
}
CPP
${CXX:-c++} -std=c++20 -Wall -Wextra -Werror -Wno-sign-compare -include initializer_list -fsanitize=address,undefined -fno-omit-frame-pointer "$work/check.cpp" -o "$work/check"
"$work/check"
printf 'APM actual-source readiness, basic errors/ACK, stale/truncated replies, probe and removal fixtures passed.\n'
