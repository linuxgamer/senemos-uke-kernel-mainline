#!/usr/bin/env bash
# Exercise actual PRM transactions with synthetic transport and IRQ scheduling.
set -euo pipefail
kernel=${1:?Pass prepared kernel tree}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
prm=$kernel/sound/soc/qcom/qdsp6/q6prm.c
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
typedef uint32_t u32;
struct device { void *data; };
typedef struct { struct device dev; } gpr_device_t;
struct mutex { bool held; };
typedef struct mutex spinlock_t;
static void mutex_lock(struct mutex *m) { assert(!m->held); m->held = true; }
static void mutex_unlock(struct mutex *m) { assert(m->held); m->held = false; }
#define spin_lock_irqsave(p,f) ((f)=0,mutex_lock(p))
#define spin_unlock_irqrestore(p,f) ((void)(f),mutex_unlock(p))
struct completion { unsigned done; };
static int wakes;
static void reinit_completion(struct completion *c) { c->done=0; }
static void complete(struct completion *c) { c->done++; wakes++; }
typedef u32 atomic_t;
#define ATOMIC_INIT(n) n
static u32 atomic_inc_return(atomic_t *p) { return ++*p; }
#define __packed __attribute__((packed))
#define HZ 1
#define dev_err(...) ((void)0)
static void *dev_get_drvdata(struct device *d) { return d->data; }
C
awk '/^struct gpr_hdr \{/ {emit=1} emit {print} emit && /^} __packed;/ {emit=0}' "$kernel/include/linux/soc/qcom/apr.h" >> "$work/check.c"
awk '/^struct gpr_ibasic_rsp_result_t \{/ {emit=1} emit {print} emit && /^};/ {emit=0}' "$kernel/include/linux/soc/qcom/apr.h" >> "$work/check.c"
awk '/^#define GPR_BASIC_RSP_RESULT[[:space:]]/ {print}' "$kernel/include/linux/soc/qcom/apr.h" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
struct gpr_pkt { struct gpr_hdr hdr; };
struct gpr_resp_pkt { struct gpr_hdr hdr; void *payload; int payload_size; };
C
awk '/^struct q6prm \{/ {emit=1} emit {print} emit && /^};/ {emit=0}
 /^static atomic_t prm_next_token/ {print}
 /^#define (PRM_CMD_(RSP_)?(REQUEST|RELEASE)_HW_RSC|PARAM_ID_RSC_(HW_CORE|AUDIO_HW_CLK))[[:space:]]/ {print}' "$prm" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static int prm_callback(const struct gpr_resp_pkt *, void *, int);
static int depopulations,quiesces;
static void devm_of_platform_depopulate(struct device *dev){(void)dev;depopulations++;}
static void gpr_quiesce_service(gpr_device_t *gdev){struct q6prm *p=gdev->dev.data;assert(p->removing && !p->lock.held && !p->token);quiesces++;}
static gpr_device_t *active_device;
static struct gpr_resp_pkt replies[3];
static struct gpr_ibasic_rsp_result_t results[3];
static bool current_token[3],immediate;
static int reply_count,reply_next,send_error,sends,callback_error;
static u32 sent_token;
static void inject_reply(void)
{
 int ret=prm_callback(&replies[reply_next++],active_device,0);
 if (ret) callback_error=ret;
}
static int gpr_send_pkt(gpr_device_t *gdev,const struct gpr_pkt *pkt)
{
 struct q6prm *prm=gdev->dev.data;
 assert(prm->lock.held && !prm->response_lock.held && prm->token==pkt->hdr.token && prm->token);
 assert(pkt->hdr.opcode==PRM_CMD_REQUEST_HW_RSC || pkt->hdr.opcode==PRM_CMD_RELEASE_HW_RSC);
 active_device=gdev;sent_token=pkt->hdr.token;sends++;
 for (int i=0;i<reply_count;i++) if (current_token[i]) replies[i].hdr.token=sent_token;
 if (immediate && !send_error) inject_reply();
 return send_error;
}
static int wait_for_completion_timeout(struct completion *c,unsigned timeout)
{
 assert(timeout==5*HZ);
 while (!c->done && reply_next<reply_count) inject_reply();
 if (!c->done) return 0;
 c->done--;return 1;
}
C
awk '/^static int (q6prm_send_cmd_sync|prm_callback)\(/ {emit=1}
 /^static void prm_remove\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$prm" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static void response(int i,u32 opcode,u32 word,u32 status)
{
 results[i]=(struct gpr_ibasic_rsp_result_t){word,status};
 replies[i]=(struct gpr_resp_pkt){.hdr={.opcode=opcode},.payload=&results[i],.payload_size=sizeof(results[i])};
 current_token[i]=true;
}
static int request(struct q6prm *prm,u32 cmd,u32 rsp,u32 param)
{
 struct gpr_pkt pkt={.hdr={.opcode=cmd}};
 reply_next=callback_error=0;
 int ret=q6prm_send_cmd_sync(prm,&pkt,rsp,param);
 assert(!prm->lock.held && !prm->response_lock.held && !prm->token);
 return ret;
}
int main(void)
{
 struct q6prm prm={0};gpr_device_t gdev={.dev={&prm}};
 prm.gdev=&gdev;prm.dev=&gdev.dev;
 _Static_assert(sizeof(results[0])==8,"PRM response wire size");
 const u32 cmds[]={PRM_CMD_REQUEST_HW_RSC,PRM_CMD_RELEASE_HW_RSC};
 const u32 rsps[]={PRM_CMD_RSP_REQUEST_HW_RSC,PRM_CMD_RSP_RELEASE_HW_RSC};
 const u32 params[]={PARAM_ID_RSC_AUDIO_HW_CLK,PARAM_ID_RSC_HW_CORE};
 for (unsigned i=0;i<2;i++) for (unsigned j=0;j<2;j++) {
  u32 cmd=cmds[i],rsp=rsps[i],param=params[j];int before;
  reply_count=1;response(0,rsp,param,0);before=wakes;
  assert(request(&prm,cmd,rsp,param)==0 && wakes==before+1);
  u32 previous=sent_token;
  response(0,rsp,param,9);current_token[0]=false;replies[0].hdr.token=previous;
  response(1,rsp,param,0);reply_count=2;before=wakes;
  assert(request(&prm,cmd,rsp,param)==0 && reply_next==2 && wakes==before+1 && sent_token!=previous);
  response(0,rsp,param,0);response(1,rsp,param,99);before=wakes;
  assert(request(&prm,cmd,rsp,param)==0 && reply_next==1 && wakes==before+1);
  inject_reply();assert(prm.status==0 && !prm.done.done && wakes==before+1);
  reply_count=1;response(0,rsp,param,0);current_token[0]=false;replies[0].hdr.token=0;before=wakes;
  assert(request(&prm,cmd,rsp,param)==-ETIMEDOUT && wakes==before);
  response(0,rsp,param^1U,0);assert(request(&prm,cmd,rsp,param)==-ETIMEDOUT && wakes==before);
  response(0,rsps[i^1U],param,0);assert(request(&prm,cmd,rsp,param)==-ETIMEDOUT && wakes==before);
  response(0,GPR_BASIC_RSP_RESULT,cmd,7);assert(request(&prm,cmd,rsp,param)==-EINVAL && wakes==before+1);
  response(0,GPR_BASIC_RSP_RESULT,cmds[i^1U],7);before=wakes;
  assert(request(&prm,cmd,rsp,param)==-ETIMEDOUT && wakes==before);
  response(0,GPR_BASIC_RSP_RESULT,cmd,7);current_token[0]=false;replies[0].hdr.token=previous;
  assert(request(&prm,cmd,rsp,param)==-ETIMEDOUT && wakes==before);
  for (int kind=0;kind<2;kind++) for (int len=-1;len<8;len++) {
   response(0,kind?GPR_BASIC_RSP_RESULT:rsp,kind?cmd:param,7);replies[0].payload_size=len;
   assert(request(&prm,cmd,rsp,param)==-ETIMEDOUT && wakes==before && callback_error==-EINVAL);
  }
  response(0,rsp,param,0);replies[0].payload=NULL;
  assert(request(&prm,cmd,rsp,param)==-ETIMEDOUT && wakes==before && callback_error==-EINVAL);
  response(0,GPR_BASIC_RSP_RESULT,cmd,0);
  assert(request(&prm,cmd,rsp,param)==-ETIMEDOUT && wakes==before);
  response(1,rsp,param,0);reply_count=2;
  assert(request(&prm,cmd,rsp,param)==0 && reply_next==2 && wakes==before+1);
  reply_count=1;response(0,rsp,param,7);assert(request(&prm,cmd,rsp,param)==-EINVAL);
  response(0,rsp,param,0);send_error=-EPIPE;before=wakes;int sent=sends;
  assert(request(&prm,cmd,rsp,param)==-EPIPE && !reply_next && wakes==before && sends==sent+1);
  inject_reply();assert(wakes==before && !prm.done.done);
  send_error=0;reply_count=0;assert(request(&prm,cmd,rsp,param)==-ETIMEDOUT);
  reply_count=1;response(0,rsp,param,0);immediate=true;
  assert(request(&prm,cmd,rsp,param)==0);immediate=false;
 }
 prm_next_token=UINT32_MAX;reply_count=1;response(0,rsps[0],params[0],0);
 assert(request(&prm,cmds[0],rsps[0],params[0])==0 && sent_token==1);
 struct q6prm reprobe={0};gdev.dev.data=&reprobe;reprobe.gdev=&gdev;reprobe.dev=&gdev.dev;
 response(0,rsps[0],params[0],7);current_token[0]=false;replies[0].hdr.token=sent_token;
 response(1,rsps[0],params[0],0);reply_count=2;
 assert(request(&reprobe,cmds[0],rsps[0],params[0])==0 && reply_next==2 && sent_token==2);
 prm_remove(&gdev);assert(depopulations==1 && quiesces==1);int sent=sends;
 assert(request(&reprobe,cmds[0],rsps[0],params[0])==-ENODEV && sends==sent);
}
C
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -Wno-sign-compare -Wno-unused-parameter \
    -fsanitize=address,undefined -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check"
printf 'PRM actual-source token/parameter correlation, late/duplicate/ACK/bounds/error/wrap/reprobe fixtures passed.\n'
