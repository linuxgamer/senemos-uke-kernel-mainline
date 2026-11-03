#!/usr/bin/env bash
# Execute real fragment allocation and read/write producers with fault injection.
set -euo pipefail
kernel=${1:?Pass prepared kernel tree}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <stdio.h>
typedef uint64_t phys_addr_t;
#define __packed __attribute__((packed))
#define __free(x)
#define IS_ERR(p) ((intptr_t)(p)<0 && (intptr_t)(p)>-4096)
#define PTR_ERR(p) ((intptr_t)(p))
#define GENMASK(h,l) ((~0U << (l)) & (~0U >> (31-(h))))
#define SNDRV_PCM_STREAM_PLAYBACK 0
#define SNDRV_PCM_STREAM_CAPTURE 1
#define lower_32_bits(n) ((uint32_t)(n))
#define upper_32_bits(n) ((uint32_t)((n)>>32))
#define check_mul_overflow(a,b,p) __builtin_mul_overflow(a,b,p)
#define check_add_overflow(a,b,p) __builtin_add_overflow(a,b,p)
struct mutex{bool held;};
static void mutex_lock(struct mutex *p){assert(!p->held);p->held=true;}
static void mutex_unlock(struct mutex *p){assert(p->held);p->held=false;}
static struct mutex *acquire_mutex(struct mutex *p){mutex_lock(p);return p;}
static void cleanup_mutex(struct mutex **p){mutex_unlock(*p);}
#define guard(name) struct mutex *guard_instance __attribute__((cleanup(cleanup_##name)))=acquire_##name
struct gpr_hdr{uint32_t opcode,token;};
struct gpr_pkt{struct gpr_hdr hdr;uint32_t payload[16];};
#define GPR_HDR_SIZE sizeof(struct gpr_hdr)
C
awk '/^#define (DATA_CMD_WR_SH_MEM_EP_DATA_BUFFER_V2|DATA_CMD_RD_SH_MEM_EP_DATA_BUFFER_V2)[[:space:]]/ {print}
 /^struct (apm_data_cmd_wr_sh_mem_ep_data_buffer_v2|data_cmd_rd_sh_mem_ep_data_buffer_v2) \{/ {emit=1}
 emit {print} emit && /^} __packed;/ {emit=0}' "$kernel/sound/soc/qcom/qdsp6/audioreach.h" >> "$work/check.c"
awk '/^#define APM_WRITE_TOKEN_(MASK|LEN_MASK|LEN_SHIFT)[[:space:]]/ {print}
 /^struct audio_buffer \{/ {emit=1} emit {print} emit && /^};/ {emit=0}' "$kernel/sound/soc/qcom/qdsp6/q6apm.h" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
struct audioreach_graph_data{struct audio_buffer *buf;uint32_t num_periods,dsp_buf;};
struct graph_info{uint32_t mem_map_handle;};
struct port{uint32_t id;};
struct q6apm_graph{struct mutex lock;struct audioreach_graph_data rx_data,tx_data;struct port *port;uint32_t shm_iid;struct graph_info *info;};
static struct gpr_pkt packet;
static bool allocation_fail;
static int send_error,sends;
static struct gpr_pkt *audioreach_alloc_pkt(int size,uint32_t opcode,uint32_t token,uint32_t port,uint32_t iid){
 (void)port;(void)iid;assert(size<=(int)sizeof(packet.payload));if(allocation_fail)return(void*)(intptr_t)-ENOMEM;
 packet=(struct gpr_pkt){.hdr={opcode,token}};return &packet;
}
static int gpr_send_port_pkt(struct port *port,const struct gpr_pkt *pkt){(void)port;(void)pkt;sends++;return send_error?send_error:1;}
static void *allocate_fragments(size_t n,size_t size){return allocation_fail?NULL:calloc(n,size);}
#define kzalloc_objs(type,n) allocate_fragments(n,sizeof(type))
C
awk '/^(int q6apm_alloc_fragments|int q6apm_write_async|int q6apm_read)\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$kernel/sound/soc/qcom/qdsp6/q6apm.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
int main(void){
 (void)acquire_mutex;(void)cleanup_mutex;
 uint32_t big=128*1024,token=7U|(big<<APM_WRITE_TOKEN_LEN_SHIFT);
 if((token>>APM_WRITE_TOKEN_LEN_SHIFT)!=big)fprintf(stderr,"Advertised 128KiB fragment truncates to %u bytes in token\n",token>>APM_WRITE_TOKEN_LEN_SHIFT);
 assert((token>>APM_WRITE_TOKEN_LEN_SHIFT)==big && (token&APM_WRITE_TOKEN_MASK)==7);
 struct port port={17};struct graph_info info={99};struct audio_buffer buffers[2]={{0x123456789ULL,131072},{0x123476789ULL,131072}};
 struct q6apm_graph g={.rx_data={buffers,2,0},.tx_data={buffers,2,0},.port=&port,.shm_iid=42,.info=&info};
 assert(q6apm_write_async(&g,big,1,2,3)==1 && g.rx_data.dsp_buf==1 && !g.lock.held);
 struct apm_data_cmd_wr_sh_mem_ep_data_buffer_v2 *wr=(void*)packet.payload;
 assert(packet.hdr.token>>APM_WRITE_TOKEN_LEN_SHIFT==big && !(packet.hdr.token&APM_WRITE_TOKEN_MASK));
 assert(wr->buf_size==big && wr->mem_map_handle==99 && wr->timestamp_msw==1 && wr->timestamp_lsw==2 && wr->flags==3 && wr->buf_addr_msw==1);
 assert(q6apm_write_async(&g,65536,0,0,0)==1 && g.rx_data.dsp_buf==0 && (packet.hdr.token&APM_WRITE_TOKEN_MASK)==1);
 send_error=-EPIPE;assert(q6apm_write_async(&g,128,0,0,0)==-EPIPE && !g.rx_data.dsp_buf);send_error=0;
 allocation_fail=true;assert(q6apm_write_async(&g,128,0,0,0)==-ENOMEM && !g.rx_data.dsp_buf);allocation_fail=false;
 int before=sends;assert(q6apm_write_async(&g,0,0,0,0)==-EINVAL);
 assert(q6apm_write_async(&g,131073,0,0,0)==-EINVAL);
 assert(q6apm_write_async(&g,UINT32_MAX,0,0,0)==-EINVAL);
 g.rx_data.dsp_buf=2;assert(q6apm_write_async(&g,128,0,0,0)==-EINVAL);g.rx_data.dsp_buf=0;
 g.rx_data.buf=NULL;assert(q6apm_write_async(&g,128,0,0,0)==-EINVAL);g.rx_data.buf=buffers;
 assert(sends==before && !g.lock.held);
 assert(q6apm_read(&g)==1 && g.tx_data.dsp_buf==1 && packet.hdr.token==0);
 struct data_cmd_rd_sh_mem_ep_data_buffer_v2 *rd=(void*)packet.payload;assert(rd->buf_size==big && rd->mem_map_handle==99);
 send_error=-EPIPE;assert(q6apm_read(&g)==-EPIPE && g.tx_data.dsp_buf==1);send_error=0;
 allocation_fail=true;assert(q6apm_read(&g)==-ENOMEM && g.tx_data.dsp_buf==1);allocation_fail=false;
 g.tx_data.dsp_buf=2;assert(q6apm_read(&g)==-EINVAL);g.tx_data.dsp_buf=1;
 g.tx_data.buf=NULL;assert(q6apm_read(&g)==-EINVAL);g.tx_data.buf=buffers;
 assert(q6apm_read(&g)==1 && g.tx_data.dsp_buf==0 && !g.lock.held);
 g.rx_data.buf=NULL;g.rx_data.num_periods=0;
 before=sends;assert(q6apm_alloc_fragments(&g,0,0x1000,4096,0)==-EINVAL);
 assert(q6apm_alloc_fragments(&g,0,0x1000,0,2)==-EINVAL);
 assert(q6apm_alloc_fragments(&g,2,0x1000,4096,2)==-EINVAL);
 assert(q6apm_alloc_fragments(&g,0,0x1000,4096,APM_WRITE_TOKEN_MASK+2U)==-EINVAL);
 assert(q6apm_alloc_fragments(&g,0,UINT64_MAX-1024,4096,2)==-EINVAL);
 allocation_fail=true;assert(q6apm_alloc_fragments(&g,0,0x1000,4096,2)==-ENOMEM);allocation_fail=false;
 assert(!g.rx_data.buf && q6apm_alloc_fragments(&g,0,0x1000,4096,2)==0 && g.rx_data.num_periods==2);
 assert(g.rx_data.buf[1].phys==0x2000 && g.rx_data.buf[1].size==4096);
 g.rx_data.dsp_buf=1;assert(q6apm_alloc_fragments(&g,0,0x1000,4096,2)==0 && g.rx_data.dsp_buf==1);
 assert(q6apm_alloc_fragments(&g,0,0x2000,4096,2)==-EBUSY && g.rx_data.dsp_buf==1);
 free(g.rx_data.buf);assert(sends==before && !g.lock.held);
}
C
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -Wno-sign-compare \
    -fsanitize=address,undefined -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check"
printf 'Audio actual-source 128KiB tokens, fragment ranges, submit bounds and failure index fixtures passed.\n'
