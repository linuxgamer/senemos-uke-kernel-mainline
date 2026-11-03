#!/usr/bin/env bash
# Exercise real dynamic-port free/receive and graph close with a blocked callback.
set -euo pipefail
kernel=${1:?Pass prepared kernel tree}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <pthread.h>
#include <time.h>
typedef uint32_t u32;
#define __packed __attribute__((packed))
#define EXPORT_SYMBOL_GPL(x)
#define dev_err(...) ((void)0)
struct mutex {pthread_mutex_t lock;};
static void mutex_lock(struct mutex *m){assert(!pthread_mutex_lock(&m->lock));}
static void mutex_unlock(struct mutex *m){assert(!pthread_mutex_unlock(&m->lock));}
#define spin_lock_irqsave(p,f) ((f)=0,mutex_lock(p))
#define spin_unlock_irqrestore(p,f) ((void)(f),mutex_unlock(p))
struct gpr_resp_pkt;
struct pkt_router_svc;
struct packet_router {struct mutex svcs_lock,callback_lock;struct pkt_router_svc *svcs_idr;void *dev;};
struct pkt_router_svc {int (*callback)(const struct gpr_resp_pkt*,void*,int);void *priv;struct packet_router *pr;int id;};
typedef struct pkt_router_svc gpr_port_t;
static struct pkt_router_svc *idr_find(struct pkt_router_svc **p,u32 port){return *p && port==(u32)(*p)->id?*p:NULL;}
static void idr_remove(struct pkt_router_svc **p,u32 port){assert(*p && port==(u32)(*p)->id);*p=NULL;}
static pthread_mutex_t sync_lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t sync_cv=PTHREAD_COND_INITIALIZER;
static bool port_freed,graph_freed,entered,released,closing;
static void fake_free(void *p){assert(p);pthread_mutex_lock(&sync_lock);port_freed=true;pthread_cond_broadcast(&sync_cv);pthread_mutex_unlock(&sync_lock);}
#define kfree(p) fake_free(p)
C
awk '/^struct gpr_hdr \{/ {emit=1} emit {print} emit && /^} __packed;/ {emit=0}' "$kernel/include/linux/soc/qcom/apr.h" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
#define GPR_PKT_VER 0
#define GPR_PKT_HEADER_WORD_SIZE 6
#define GPR_PKT_HEADER_BYTE_SIZE 24
struct gpr_resp_pkt{struct gpr_hdr hdr;void *payload;int payload_size;};
struct apr_rx_buf{int len;unsigned char buf[24];};
C
awk '/^(void gpr_free_port|static int gpr_do_rx_callback)\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$kernel/drivers/soc/qcom/apr.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static int receive(const struct gpr_resp_pkt *r,void *p,int op){
 (void)r;(void)op;gpr_port_t *port=p;
 pthread_mutex_lock(&sync_lock);entered=true;pthread_cond_broadcast(&sync_cv);
 while(!released)pthread_cond_wait(&sync_cv,&sync_lock);
 assert(port->id==1 && !port_freed);pthread_mutex_unlock(&sync_lock);return 0;
}
struct audioreach_graph{int refcount;};
struct q6apm_graph{struct audioreach_graph *ar_graph;gpr_port_t *port;};
static void q6apm_put_audioreach_graph(int *p){(void)p;}
static void kref_put(int *p,void (*put)(int*)){(void)put;assert(port_freed);*p=0;}
#undef kfree
#define kfree(p) ((void)(p),graph_freed=true)
C
awk '/^int q6apm_graph_close\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$kernel/sound/soc/qcom/qdsp6/q6apm.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static struct packet_router router={.svcs_lock={PTHREAD_MUTEX_INITIALIZER},.callback_lock={PTHREAD_MUTEX_INITIALIZER}};
static struct apr_rx_buf buffer;
static void *rx_thread(void *p){(void)p;assert(gpr_do_rx_callback(&router,&buffer)==0);return NULL;}
static void *close_thread(void *p){
 pthread_mutex_lock(&sync_lock);closing=true;pthread_cond_broadcast(&sync_cv);pthread_mutex_unlock(&sync_lock);
 gpr_free_port(p);return NULL;
}
int main(void){
 gpr_port_t port={receive,NULL,&router,1};port.priv=&port;router.svcs_idr=&port;
 buffer.len=24;struct gpr_hdr *hdr=(void*)buffer.buf;hdr->hdr_size=6;hdr->pkt_size=24;hdr->dest_port=1;
 pthread_t rx,close;assert(!pthread_create(&rx,NULL,rx_thread,NULL));
 pthread_mutex_lock(&sync_lock);while(!entered)pthread_cond_wait(&sync_cv,&sync_lock);pthread_mutex_unlock(&sync_lock);
 assert(!pthread_create(&close,NULL,close_thread,&port));
 pthread_mutex_lock(&sync_lock);while(!closing)pthread_cond_wait(&sync_cv,&sync_lock);
 struct timespec until;assert(!clock_gettime(CLOCK_REALTIME,&until));until.tv_nsec+=30000000;
 if(until.tv_nsec>=1000000000){until.tv_sec++;until.tv_nsec-=1000000000;}
 while(!port_freed){int ret=pthread_cond_timedwait(&sync_cv,&sync_lock,&until);if(ret==ETIMEDOUT)break;assert(!ret);}
 if(port_freed)fprintf(stderr,"GPR free completed while its callback was active\n");
 assert(!port_freed);released=true;pthread_cond_broadcast(&sync_cv);pthread_mutex_unlock(&sync_lock);
 assert(!pthread_join(rx,NULL) && !pthread_join(close,NULL));assert(port_freed && !router.svcs_idr);
 assert(gpr_do_rx_callback(&router,&buffer)==-EINVAL);
 port_freed=false;port.callback=NULL;router.svcs_idr=&port;
 assert(gpr_do_rx_callback(&router,&buffer)==0);gpr_free_port(&port);assert(port_freed);
 port_freed=false;router.svcs_idr=&port;struct audioreach_graph ar={1};struct q6apm_graph graph={&ar,&port};
 assert(q6apm_graph_close(&graph)==0 && port_freed && graph_freed && ar.refcount==0 && !graph.ar_graph);
}
C
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -Wno-sign-compare -pthread \
    -fsanitize=address,undefined -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check"
printf 'GPR actual-source in-flight callback/free and graph-close ordering fixtures passed.\n'
