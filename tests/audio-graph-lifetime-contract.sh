#!/usr/bin/env bash
# Execute actual graph get/put and failed-open cleanup with synthetic firmware.
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
#include <stdlib.h>
#include <stddef.h>
#include <limits.h>
#include <stdio.h>
#define IS_ERR(p) ((intptr_t)(p)<0 && (intptr_t)(p)>-4096)
#define ERR_PTR(n) ((void*)(intptr_t)(n))
#define ERR_CAST(p) ((void*)(p))
#define PTR_ERR(p) ((intptr_t)(p))
#define GFP_KERNEL 0
#define dev_err(...) ((void)0)
#define container_of(p,t,m) ((t*)((char*)(p)-offsetof(t,m)))
struct mutex{bool held;};
static void mutex_lock(struct mutex *m){assert(!m->held);m->held=true;}
static void mutex_unlock(struct mutex *m){assert(m->held);m->held=false;}
static struct mutex *acquire_mutex(struct mutex *m){mutex_lock(m);return m;}
static void cleanup_mutex(struct mutex **m){mutex_unlock(*m);}
#define JOIN_INNER(a,b) a##b
#define JOIN(a,b) JOIN_INNER(a,b)
#define guard(name) struct mutex *JOIN(guard_instance,__COUNTER__) __attribute__((cleanup(cleanup_##name)))=acquire_##name
struct kref{int count;};
static void kref_init(struct kref *r){r->count=1;}
static void kref_get(struct kref *r){assert(r->count>0);r->count++;}
static bool kref_get_unless_zero(struct kref *r){if(!r->count)return false;r->count++;return true;}
static void kref_put(struct kref *r,void(*put)(struct kref*)){assert(r->count>0);if(!--r->count)put(r);}
struct idr{void *slots[16];};
static void *idr_find(struct idr *id,uint32_t key){return key<16?id->slots[key]:NULL;}
static int id_error;
static int idr_alloc(struct idr *id,void *p,uint32_t start,uint32_t end,int flags){(void)flags;assert(end==start+1);if(id_error)return id_error;if(start>=16||id->slots[start])return -ENOSPC;id->slots[start]=p;return start;}
static void *idr_remove(struct idr *id,uint32_t key){assert(key<16);void *p=id->slots[key];id->slots[key]=NULL;return p;}
#define idr_for_each_entry(id,p,key) for((key)=0;(key)<16;(key)++)if(((p)=(id)->slots[key]))
struct audioreach_graph_info{int unused;};
struct q6apm{void *dev;struct mutex lock,cmd_lock;struct idr graph_idr,graph_info_idr;bool removing;};
struct audioreach_graph{struct audioreach_graph_info *info;uint32_t id;int state,start_count;void *graph;struct kref refcount;struct q6apm *apm;};
static int allocations,allocation_error,packet_error,send_error,sends,closes;
static bool send_locked;
static void *allocate(size_t size){if(allocation_error)return NULL;allocations++;return calloc(1,size);}
#define kzalloc_obj(obj) allocate(sizeof(obj))
static void kfree(void *p){assert(p);allocations--;free(p);}
static void *audioreach_alloc_graph_pkt(struct q6apm *a,struct audioreach_graph_info *i){(void)a;(void)i;return packet_error?ERR_PTR(packet_error):allocate(8);}
static int q6apm_send_cmd_sync(struct q6apm *a,void *p,uint32_t op){(void)p;(void)op;sends++;send_locked=a->cmd_lock.held;assert(!a->lock.held);return send_error;}
#define APM_CMD_GRAPH_CLOSE 1
static int audioreach_graph_mgmt_cmd(struct audioreach_graph *g,uint32_t op){assert(op==APM_CMD_GRAPH_CLOSE && g->apm->cmd_lock.held);closes++;return 0;}
C
awk '/^static struct audioreach_graph \*q6apm_get_audioreach_graph\(/ {emit=1}
 /^static void q6apm_(put_audioreach_graph|purge_failed_graphs)\(/ {emit=1}
 /^static void q6apm_purge_failed_graphs\(/ {print "#define HAVE_PURGE 1"}
 emit {print} emit && /^}/ {emit=0}' "$source" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
int main(void){
 (void)acquire_mutex;(void)cleanup_mutex;(void)kref_get;(void)kref_get_unless_zero;
 struct q6apm apm={0};struct audioreach_graph_info info={0};apm.graph_info_idr.slots[3]=&info;
 send_error=-ETIMEDOUT;struct audioreach_graph *g=q6apm_get_audioreach_graph(&apm,3);
 if(!IS_ERR(g))fprintf(stderr,"Failed firmware graph open returned a live graph\n");
 assert(IS_ERR(g) && PTR_ERR(g)==-ETIMEDOUT && !apm.lock.held && !apm.cmd_lock.held);
 int before=sends;send_error=0;g=q6apm_get_audioreach_graph(&apm,3);
 assert(IS_ERR(g) && PTR_ERR(g)==-ETIMEDOUT && sends==before);
#ifdef HAVE_PURGE
 q6apm_purge_failed_graphs(&apm);assert(!allocations && !apm.graph_idr.slots[3]);
#endif
 g=q6apm_get_audioreach_graph(&apm,3);assert(!IS_ERR(g) && g->refcount.count==1 && send_locked);
 struct audioreach_graph *same=q6apm_get_audioreach_graph(&apm,3);assert(same==g && g->refcount.count==2);
 apm.removing=true;before=sends;assert(PTR_ERR(q6apm_get_audioreach_graph(&apm,3))==-ENODEV && sends==before && g->refcount.count==2);apm.removing=false;
 kref_put(&g->refcount,q6apm_put_audioreach_graph);assert(g->refcount.count==1 && !closes);
 g->refcount.count=0;before=sends;same=q6apm_get_audioreach_graph(&apm,3);
 assert(IS_ERR(same) && PTR_ERR(same)==-EBUSY && sends==before);
 g->refcount.count=1;kref_put(&g->refcount,q6apm_put_audioreach_graph);assert(!allocations && closes==1 && !apm.graph_idr.slots[3]);
 assert(PTR_ERR(q6apm_get_audioreach_graph(&apm,UINT32_MAX))==-EINVAL);
 assert(PTR_ERR(q6apm_get_audioreach_graph(&apm,4))==-ENODEV);
 allocation_error=1;assert(PTR_ERR(q6apm_get_audioreach_graph(&apm,3))==-ENOMEM);allocation_error=0;
 packet_error=-EIO;assert(PTR_ERR(q6apm_get_audioreach_graph(&apm,3))==-EIO && !allocations);packet_error=0;
 id_error=-ENOSPC;assert(PTR_ERR(q6apm_get_audioreach_graph(&apm,3))==-ENOSPC && !allocations);id_error=0;
 assert(!apm.lock.held && !apm.cmd_lock.held);
}
C
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check"
printf 'APM actual-source graph open errors, poisoned retry, zero-ref lookup and cleanup fixtures passed.\n'
