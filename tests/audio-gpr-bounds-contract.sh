#!/usr/bin/env bash
# Exercise the actual GPR receive function with hostile packet lengths.
set -euo pipefail
kernel=${1:?Pass prepared kernel tree}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
typedef uint32_t u32;
#define __packed __attribute__((packed))
C
# Header wire layout is copied directly from the kernel under test.
awk '/^struct gpr_hdr \{/ {emit=1} emit {print} emit && /^} __packed;/ {exit}' "$kernel/include/linux/soc/qcom/apr.h" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
#define GPR_PKT_VER 0
#define GPR_PKT_HEADER_WORD_SIZE 6
#define GPR_PKT_HEADER_BYTE_SIZE 24
struct gpr_resp_pkt{struct gpr_hdr hdr;void *payload;int payload_size;};
struct apr_rx_buf{int len;unsigned char buf[];};
struct pkt_router_svc{int (*callback)(const struct gpr_resp_pkt*,void*,int);void *priv;};
struct packet_router{int svcs_lock,svcs_idr,callback_lock;void *dev;};
static void mutex_lock(int *p){assert(!*p);*p=1;}
static void mutex_unlock(int *p){assert(*p==1);*p=0;}
static int calls;
static int expected_size;
static void *expected_payload;
static int receive(const struct gpr_resp_pkt *r,void *p,int op){
 (void)p;(void)op;assert(r->payload_size==expected_size);
 assert(r->payload==expected_payload);calls++;return 0;
}
static struct pkt_router_svc service={receive,NULL};
static void *idr_find(int *id,u32 port){(void)id;return port==1?&service:NULL;}
#define spin_lock_irqsave(p,f) ((void)(p),(f)=0)
#define spin_unlock_irqrestore(p,f) ((void)(p),(void)(f))
#define dev_err(...) ((void)0)
C
awk '/^static int gpr_do_rx_callback\(/ {emit=1} emit {print} emit && /^}/ {exit}' "$kernel/drivers/soc/qcom/apr.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static struct apr_rx_buf *packet(int len){
 struct apr_rx_buf *b=calloc(1,sizeof(*b)+len);assert(b);b->len=len;
 if(len>=24){struct gpr_hdr *h=(void*)b->buf;h->hdr_size=6;h->pkt_size=len;h->dest_port=1;}
 return b;
}
int main(void){
 struct packet_router router={0};
 for(int len=0;len<24;len++){struct apr_rx_buf *b=packet(len);assert(gpr_do_rx_callback(&router,b)==-EINVAL);free(b);}
 struct apr_rx_buf *b=packet(24);struct gpr_hdr *h=(void*)b->buf;
 expected_size=0;expected_payload=NULL;assert(gpr_do_rx_callback(&router,b)==0&&calls==1);
 h->hdr_size=7;assert(gpr_do_rx_callback(&router,b)==-EINVAL&&calls==1);
 h->hdr_size=5;assert(gpr_do_rx_callback(&router,b)==-EINVAL);
 h->hdr_size=6;h->pkt_size=28;assert(gpr_do_rx_callback(&router,b)==-EINVAL);
 h->pkt_size=24;h->version=2;assert(gpr_do_rx_callback(&router,b)==-EINVAL);free(b);
 b=packet(32);h=(void*)b->buf;h->hdr_size=7;
 expected_size=4;expected_payload=b->buf+28;assert(gpr_do_rx_callback(&router,b)==0&&calls==2);
 h->dest_port=2;assert(gpr_do_rx_callback(&router,b)==-EINVAL);free(b);
 assert(!router.callback_lock);
}
C
${CC:-cc} -std=c11 -Wall -Wextra -Werror -Wno-sign-compare -Wno-unused-parameter -fsanitize=address,undefined -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check"
printf 'GPR actual-source header and packet bounds fixtures passed.\n'
