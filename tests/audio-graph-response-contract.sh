#!/usr/bin/env bash
# Compile the full graph callback with real wire structs and hostile replies.
set -euo pipefail
kernel=${1:?Pass prepared kernel tree}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
typedef uint32_t u32;
typedef uint64_t phys_addr_t;
#define __packed __attribute__((packed))
#define GENMASK(h,l) ((~0U << (l)) & (~0U >> (31-(h))))
#define dev_err(...) ((void)0)
#define lower_32_bits(n) ((u32)(n))
#define upper_32_bits(n) ((u32)((n)>>32))
struct mutex {bool held;};
static void mutex_lock(struct mutex *p){assert(!p->held);p->held=true;}
static void mutex_unlock(struct mutex *p){assert(p->held);p->held=false;}
static void atomic_set(int *p,int value){*p=value;}
#define wake_up(p) (++*(p))
struct device {int unused;};
struct gpr_hdr {u32 opcode,token;};
struct gpr_resp_pkt {struct gpr_hdr hdr;void *payload;int payload_size;};
struct gpr_ibasic_rsp_result_t {u32 opcode,status;};
C
awk '/^#define (APM_EVENT_MODULE_TO_CLIENT|EVENT_ID_SH_MEM_PULL_PUSH_MODE_WATERMARK|DATA_CMD_RSP_WR_SH_MEM_EP_DATA_BUFFER_DONE_V2|DATA_CMD_RSP_RD_SH_MEM_EP_DATA_BUFFER_V2|DATA_CMD_WR_SH_MEM_EP_EOS_RENDERED|APM_CMD_SHARED_MEM_MAP_REGIONS|DATA_CMD_WR_SH_MEM_EP_MEDIA_FORMAT|APM_CMD_REGISTER_MODULE_EVENTS|APM_CMD_SET_CFG)[[:space:]]/ {print}
 /^struct (apm_module_event|data_cmd_rsp_wr_sh_mem_ep_data_buffer_done_v2|data_cmd_rsp_rd_sh_mem_ep_data_buffer_done|data_cmd_rsp_rd_sh_mem_ep_data_buffer_done_v2) \{/ {emit=1}
 emit {print} emit && /^} __packed;/ {emit=0}' "$kernel/sound/soc/qcom/qdsp6/audioreach.h" >> "$work/check.c"
awk '/^#define (APM_CLIENT_EVENT_(WATERMARK_EVENT|DATA_WRITE_DONE|DATA_READ_DONE|CMD_EOS_DONE)|APM_WRITE_TOKEN_(MASK|LEN_SHIFT))[[:space:]]/ {print}' "$kernel/sound/soc/qcom/qdsp6/q6apm.h" >> "$work/check.c"
awk '/^#define GPR_BASIC_RSP_RESULT[[:space:]]/ {print}' "$kernel/include/linux/soc/qcom/apr.h" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
struct audio_buffer {phys_addr_t phys;size_t size;};
struct audioreach_graph_data {struct audio_buffer *buf;u32 num_periods;int hw_ptr;};
struct q6apm_graph {struct device *dev;void *ar_graph;struct mutex lock;struct audioreach_graph_data rx_data,tx_data;struct gpr_ibasic_rsp_result_t result;void (*cb)(u32,u32,void*,void*);void *priv;int cmd_wait;};
static int calls;
static void client(u32 opcode,u32 token,void *payload,void *priv){(void)opcode;(void)token;(void)payload;(void)priv;calls++;}
C
awk '/^static int graph_callback\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$kernel/sound/soc/qcom/qdsp6/q6apm.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
int main(void){
 struct device dev={0};struct audio_buffer buffers[2]={{0x123456789ULL,4096},{0x987654321ULL,4096}};
 struct q6apm_graph g={.dev=&dev,.ar_graph=&dev,.rx_data={buffers,1,0},.tx_data={buffers,1,0},.cb=client};
 struct data_cmd_rsp_wr_sh_mem_ep_data_buffer_done_v2 wr={.buf_addr_lsw=lower_32_bits(buffers[1].phys),.buf_addr_msw=upper_32_bits(buffers[1].phys)};
 struct gpr_resp_pkt r={.hdr={DATA_CMD_RSP_WR_SH_MEM_EP_DATA_BUFFER_DONE_V2,1},.payload=&wr,.payload_size=sizeof(wr)};
 int ret=graph_callback(&r,&g,0);
 if(ret!=-EINVAL)fprintf(stderr,"Out-of-range graph token returned %d; expected %d\n",ret,-EINVAL);
 assert(ret==-EINVAL && !calls && !g.rx_data.hw_ptr && !g.lock.held);
 for(int len=-1;len<(int)sizeof(wr);len++){r.payload_size=len;assert(graph_callback(&r,&g,0)==-EINVAL && !calls);}
 r.payload_size=sizeof(wr);r.payload=NULL;assert(graph_callback(&r,&g,0)==-EINVAL);
 r.payload=&wr;r.hdr.token=0;wr.buf_addr_lsw=lower_32_bits(buffers[0].phys);wr.buf_addr_msw=upper_32_bits(buffers[0].phys);
 wr.buf_addr_lsw^=1;
 assert(graph_callback(&r,&g,0)==-EINVAL && !calls && !g.rx_data.hw_ptr);
 wr.buf_addr_lsw^=1;wr.status=7;
 assert(graph_callback(&r,&g,0)==-EIO && !calls && !g.rx_data.hw_ptr);wr.status=0;
 r.hdr.token=4097U<<APM_WRITE_TOKEN_LEN_SHIFT;
 assert(graph_callback(&r,&g,0)==-EINVAL && !calls && !g.rx_data.hw_ptr);r.hdr.token=0;
 assert(graph_callback(&r,&g,0)==0 && calls==1 && g.rx_data.hw_ptr==1);
 r.hdr.token=UINT32_MAX;assert(graph_callback(&r,&g,0)==-EINVAL && calls==1);
 g.rx_data.buf=NULL;r.hdr.token=0;assert(graph_callback(&r,&g,0)==0 && calls==1);g.rx_data.buf=buffers;
 _Static_assert(sizeof(struct data_cmd_rsp_rd_sh_mem_ep_data_buffer_done_v2)==56,"V2 wire reply is 14 words");
 _Static_assert(offsetof(struct data_cmd_rsp_rd_sh_mem_ep_data_buffer_done_v2,timestamp_lsw)==20,"V2 has no offset");
 _Static_assert(offsetof(struct data_cmd_rsp_rd_sh_mem_ep_data_buffer_done_v2,md_status)==36,"V2 metadata status");
 _Static_assert(offsetof(struct data_cmd_rsp_rd_sh_mem_ep_data_buffer_done_v2,md_size)==52,"V2 metadata size");
 _Static_assert(sizeof(struct data_cmd_rsp_rd_sh_mem_ep_data_buffer_done)==40,"V1 unchanged");
 _Static_assert(offsetof(struct data_cmd_rsp_rd_sh_mem_ep_data_buffer_done,offset)==20,"V1 retains offset");
 /* Independent 56-byte protocol vector; timestamp is not a data offset. */
 const unsigned char wire[56]={
  0,0,0,0, 0x89,0x67,0x45,0x23, 1,0,0,0, 0,0,0,0,
  0,0x10,0,0, 0xef,0xbe,0xad,0xde, 0x78,0x56,0x34,0x12, 0,0,0,0x80,
  1,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0
 };
 struct data_cmd_rsp_rd_sh_mem_ep_data_buffer_done_v2 rd;
 memcpy(&rd,wire,sizeof(rd));
 assert(rd.data_size==4096 && rd.timestamp_lsw==0xdeadbeef && rd.timestamp_msw==0x12345678);
 r=(struct gpr_resp_pkt){.hdr={DATA_CMD_RSP_RD_SH_MEM_EP_DATA_BUFFER_V2,1},.payload=&rd,.payload_size=sizeof(rd)};
 assert(graph_callback(&r,&g,0)==-EINVAL && calls==1 && !g.tx_data.hw_ptr && !g.lock.held);
 for(int len=-1;len<(int)sizeof(rd);len++){r.payload_size=len;assert(graph_callback(&r,&g,0)==-EINVAL && calls==1);}
 r.payload_size=sizeof(rd);r.payload=NULL;assert(graph_callback(&r,&g,0)==-EINVAL);
 r.payload=&rd;r.hdr.token=UINT32_MAX;assert(graph_callback(&r,&g,0)==-EINVAL);
 r.hdr.token=0;rd.buf_addr_lsw^=1;
 assert(graph_callback(&r,&g,0)==-EINVAL && calls==1 && !g.tx_data.hw_ptr);rd.buf_addr_lsw^=1;
 rd.status=7;assert(graph_callback(&r,&g,0)==-EIO && calls==1 && !g.tx_data.hw_ptr);rd.status=0;
 rd.data_size=4097;assert(graph_callback(&r,&g,0)==-EINVAL && calls==1 && !g.tx_data.hw_ptr);
 rd.data_size=UINT32_MAX;assert(graph_callback(&r,&g,0)==-EINVAL && calls==1 && !g.tx_data.hw_ptr);rd.data_size=4096;
 assert(graph_callback(&r,&g,0)==0 && calls==2 && g.tx_data.hw_ptr==1);
 g.tx_data.num_periods=0;assert(graph_callback(&r,&g,0)==-EINVAL && calls==2);g.tx_data.num_periods=1;
 struct {struct apm_module_event event;u32 word;} event={{EVENT_ID_SH_MEM_PULL_PUSH_MODE_WATERMARK,4},0};
 r=(struct gpr_resp_pkt){.hdr={APM_EVENT_MODULE_TO_CLIENT,0},.payload=&event,.payload_size=sizeof(event.event)};
 assert(graph_callback(&r,&g,0)==-EINVAL && calls==2);
 r.payload_size=sizeof(event);assert(graph_callback(&r,&g,0)==0 && calls==3);
 event.event.event_payload_size=UINT32_MAX;assert(graph_callback(&r,&g,0)==-EINVAL && calls==3);
 event.event.event_payload_size=0;r.payload_size=sizeof(event.event);g.cb=NULL;
 assert(graph_callback(&r,&g,0)==0 && calls==3);
 r.payload=NULL;assert(graph_callback(&r,&g,0)==-EINVAL);
 r.payload=&event;for(int len=-1;len<(int)sizeof(event.event);len++){r.payload_size=len;assert(graph_callback(&r,&g,0)==-EINVAL);}
 r.hdr.opcode=0xdead;assert(graph_callback(&r,&g,0)==0 && calls==3);
 assert(!g.lock.held);
}
C
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -Wno-sign-compare -Wno-unused-parameter -Wno-unused-variable \
    -fsanitize=address,undefined -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check"
printf 'Graph actual-source 56-byte V2 wire reply, nonzero timestamp, response bounds, period tokens and null client fixtures passed.\n'
