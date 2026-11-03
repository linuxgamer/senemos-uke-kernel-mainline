#!/usr/bin/env bash
# Extract the unmap producer, callback branch and synchronous helper.
set -euo pipefail
kernel=${1:?Pass prepared kernel tree}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
source=$kernel/sound/soc/qcom/qdsp6/q6apm.c
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
typedef uint32_t u32;
#define __packed __attribute__((packed))
#define __free(x)
#define IS_ERR(p) ((intptr_t)(p)<0 && (intptr_t)(p)>-4096)
#define PTR_ERR(p) ((intptr_t)(p))
#define BIT(n) (1U << (n))
#define GENMASK(h,l) ((~0U << (l)) & (~0U >> (31-(h))))
#define HZ 1
#define dev_err(...) ((void)0)
#define wake_up(q) (++*(q))
struct mutex { bool held; };
static void mutex_lock(struct mutex *m) { assert(!m->held); m->held = true; }
static void mutex_unlock(struct mutex *m) { assert(m->held); m->held = false; }
struct device { void *data; struct device *parent; };
static void *dev_get_drvdata(struct device *d) { return d->data; }
typedef struct { struct device dev; } gpr_device_t;
typedef int gpr_port_t;
typedef int wait_queue_head_t;
C
awk '/^struct gpr_hdr \{/ {emit=1} emit {print} emit && /^} __packed;/ {emit=0}' "$kernel/include/linux/soc/qcom/apr.h" >> "$work/check.c"
awk '/^struct gpr_ibasic_rsp_result_t \{/ {emit=1} emit {print} emit && /^};/ {emit=0}' "$kernel/include/linux/soc/qcom/apr.h" >> "$work/check.c"
awk '/^#define GPR_(HDR_SIZE|BASIC_RSP_RESULT)[[:space:]]/ {print}' "$kernel/include/linux/soc/qcom/apr.h" >> "$work/check.c"
awk '/^#define APM_(CMD_SHARED_MEM_UNMAP_REGIONS|MMAP_TOKEN_GID_MASK|MMAP_TOKEN_MAP_TYPE_POS_BUF)[[:space:]]/ {print}
 /^struct apm_cmd_shared_mem_unmap_regions \{/ {emit=1} emit {print} emit && /^} __packed;/ {emit=0}' "$kernel/sound/soc/qcom/qdsp6/audioreach.h" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
struct gpr_pkt { struct gpr_hdr hdr; u32 payload[1]; };
struct gpr_resp_pkt { struct gpr_hdr hdr; void *payload; int payload_size; };
struct q6apm { gpr_device_t *gdev; struct gpr_ibasic_rsp_result_t result; struct mutex lock; int wait,graph_info_idr; };
struct audioreach_graph_info { u32 mem_map_handle,pos_buf_mem_map_handle; };
static struct audioreach_graph_info info_slot;
static bool present = true,allocation_fail;
static struct gpr_pkt packet;
static u32 reply_status,sent_token,sent_handle;
static int sends,send_error,reply_next,reply_count;
static struct q6apm *active;
static void *idr_find(int *idr,u32 id) { (void)idr; return present && id==7 ? &info_slot : NULL; }
static struct gpr_pkt *audioreach_alloc_apm_cmd_pkt(int size,u32 opcode,u32 token)
{
 assert(size==sizeof(struct apm_cmd_shared_mem_unmap_regions));
 if (allocation_fail) return (void *)(intptr_t)-ENOMEM;
 packet = (struct gpr_pkt){ .hdr = { .opcode=opcode,.token=token } };
 return &packet;
}
static void unmap_response(struct q6apm *apm,const struct gpr_resp_pkt *data)
{
 const struct gpr_hdr *hdr=&data->hdr;
 const struct gpr_ibasic_rsp_result_t *result=data->payload;
 struct audioreach_graph_info *info;
 void *rsp __attribute__((unused));
 int graph_id __attribute__((unused)),is_pos_buf __attribute__((unused));
 switch (result->opcode) {
C
awk '/case APM_CMD_SHARED_MEM_UNMAP_REGIONS:/ {emit=1} emit && /default:/ {exit} emit {print}' "$source" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
 default: assert(false);
 }
}
static int gpr_send_pkt(gpr_device_t *gdev,const struct gpr_pkt *pkt)
{
 active=gdev->dev.data; assert(active->lock.held);
 assert(pkt->hdr.opcode==APM_CMD_SHARED_MEM_UNMAP_REGIONS);
 sent_token=pkt->hdr.token; sent_handle=pkt->payload[0]; sends++;
 return send_error;
}
static int gpr_send_port_pkt(gpr_port_t *port,const struct gpr_pkt *pkt)
{ (void)port; (void)pkt; assert(false); return -EINVAL; }
static void inject_reply(void)
{
 struct gpr_ibasic_rsp_result_t result={APM_CMD_SHARED_MEM_UNMAP_REGIONS,reply_status};
 struct gpr_resp_pkt reply={.hdr={.opcode=GPR_BASIC_RSP_RESULT,.token=sent_token},.payload=&result,.payload_size=sizeof(result)};
 reply_next++; unmap_response(active,&reply);
}
#define wait_event_timeout(q, condition, timeout) ({ \
 (void)(q); (void)(timeout); \
 while (!(condition) && reply_next<reply_count) inject_reply(); \
 (condition)?1:0; })
C
awk '/^int audioreach_send_cmd_sync\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$kernel/sound/soc/qcom/qdsp6/audioreach.c" >> "$work/check.c"
awk '/^(int q6apm_send_cmd_sync|static int __q6apm_unmap_memory_fixed_region)\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$source" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
int main(void)
{
 struct q6apm apm={0};gpr_device_t gdev={.dev={.data=&apm}};
 struct device child={.parent=&gdev.dev};apm.gdev=&gdev;
 for (int pos=0;pos<2;pos++) {
  info_slot=(struct audioreach_graph_info){42,99};reply_next=0;reply_count=1;reply_status=0;apm.wait=0;
  int ret=__q6apm_unmap_memory_fixed_region(&child,7,pos);
  if (ret) fprintf(stderr,"APM unmap success returned %d; expected 0\n",ret);
  assert(ret==0 && apm.wait==1 && !apm.lock.held);
  assert(sent_token==(7U | (pos?APM_MMAP_TOKEN_MAP_TYPE_POS_BUF:0)));
  assert(sent_handle==(pos?99U:42U));
  assert(info_slot.mem_map_handle==(pos?42U:0) && info_slot.pos_buf_mem_map_handle==(pos?0:99U));
  int before=sends;assert(__q6apm_unmap_memory_fixed_region(&child,7,pos)==0 && sends==before);
  info_slot=(struct audioreach_graph_info){42,99};reply_next=0;reply_status=7;
  assert(__q6apm_unmap_memory_fixed_region(&child,7,pos)==-EINVAL);
  assert(info_slot.mem_map_handle==42 && info_slot.pos_buf_mem_map_handle==99);
  reply_next=0;send_error=-EPIPE;
  assert(__q6apm_unmap_memory_fixed_region(&child,7,pos)==-EPIPE && !reply_next);
  assert(info_slot.mem_map_handle==42 && info_slot.pos_buf_mem_map_handle==99);
  send_error=0;reply_count=0;
  assert(__q6apm_unmap_memory_fixed_region(&child,7,pos)==-ETIMEDOUT);
  assert(info_slot.mem_map_handle==42 && info_slot.pos_buf_mem_map_handle==99);
 }
 allocation_fail=true;assert(__q6apm_unmap_memory_fixed_region(&child,7,false)==-ENOMEM);allocation_fail=false;
 present=false;int before=sends;assert(__q6apm_unmap_memory_fixed_region(&child,7,false)==-ENODEV && sends==before);
 struct gpr_ibasic_rsp_result_t result={APM_CMD_SHARED_MEM_UNMAP_REGIONS,0};
 struct gpr_resp_pkt reply={.hdr={.opcode=GPR_BASIC_RSP_RESULT,.token=7},.payload=&result,.payload_size=sizeof(result)};
 apm.wait=0;unmap_response(&apm,&reply);assert(!apm.wait && info_slot.mem_map_handle==42 && info_slot.pos_buf_mem_map_handle==99);
}
C
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -Wno-sign-compare -Wno-unused-parameter \
    -fsanitize=address,undefined -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check"
printf 'APM actual-source unmap opcode/status, data/position handles, failures and missing graph fixtures passed.\n'
