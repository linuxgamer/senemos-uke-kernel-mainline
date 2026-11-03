#!/usr/bin/env bash
# Exercise actual APR/GPR service publication failure paths without a device.
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
#include <stdlib.h>
#include <string.h>
typedef uint32_t u32;
#define GFP_KERNEL 0
#define GFP_ATOMIC 0
#define APR_NAME_SIZE 32
#define PR_TYPE_APR 0
#define PR_TYPE_GPR 1
#define dev_err(...) ((void)0)
#define dev_info(...) ((void)0)
struct device_node { int unused; };
struct device { void *data,*bus,*driver; struct device *parent; struct device_node *of_node; void (*release)(struct device *); bool initialized,named; };
struct pkt_router_svc { unsigned id; void *pr,*priv; struct device *dev; bool lock; };
struct apr_device { struct device dev; struct pkt_router_svc svc; unsigned svc_id,domain_id; char name[APR_NAME_SIZE]; const char *service_path; };
struct packet_router { bool svcs_lock,callback_lock; struct pkt_router_svc *svcs_idr; int type; };
static int aprbus, allocations, names, allocation_error, name_error, id_error, property_error, register_error, registered, device_puts;
static void *dev_get_drvdata(struct device *d) { return d->data; }
static void *allocate(size_t size) { if(allocation_error)return NULL; allocations++; return calloc(1,size); }
#define kzalloc_obj(obj) allocate(sizeof(obj))
static void kfree(void *p) { assert(p && allocations); allocations--; free(p); }
static void spin_lock_init(bool *held) { *held=false; }
static void spin_lock(bool *held) { assert(!*held); *held=true; }
static void spin_unlock(bool *held) { assert(*held); *held=false; }
#define mutex_lock spin_lock
#define mutex_unlock spin_unlock
static void apr_dev_release(struct device *d) { if(d->named)names--; kfree(d); }
static int dev_set_name(struct device *d,const char *fmt,...) { (void)fmt; if(name_error)return name_error; assert(!d->named); d->named=true; names++; return 0; }
static void device_initialize(struct device *d) { assert(!d->initialized); d->initialized=true; }
static int idr_alloc(struct pkt_router_svc **map, struct pkt_router_svc *p, u32 start, u32 end, int flags) {
 (void)flags; assert(end==start+1); if(id_error)return id_error; if(*map)return -ENOSPC; *map=p; return start;
}
static void idr_remove(struct pkt_router_svc **map, u32 id) {
 assert(*map && (*map)->id==id); struct packet_router *r=(*map)->pr;
 assert(r->svcs_lock && (r->type!=PR_TYPE_GPR || r->callback_lock)); *map=NULL;
}
static int of_property_read_string_index(struct device_node *n,const char *p,int i,const char **out) {
 (void)n; assert(!strcmp(p,"qcom,protection-domain") && i==1); if(property_error)return property_error; *out="synthetic/service"; return 0;
}
static int device_add(struct device *d) { assert(d->initialized); registered++; return register_error; }
static int device_register(struct device *d) { device_initialize(d); return device_add(d); }
static void put_device(struct device *d) { assert(d->initialized); device_puts++; d->release(d); }
C
awk '/^static int apr_add_device\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' \
 "$kernel/drivers/soc/qcom/apr.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
int main(void)
{
 (void)idr_remove; (void)device_register;
 struct packet_router router={.type=PR_TYPE_GPR}; struct device parent={.data=&router}; struct device_node node={0};
 register_error=-EIO;
 assert(apr_add_device(&parent,&node,7,2)==-EIO);
 if(router.svcs_idr)fprintf(stderr,"Failed device registration retained a freed service in the router IDR\n");
 assert(!router.svcs_idr && !allocations && !names && device_puts==1 && registered==1);
 register_error=0; property_error=-ENODATA;
 assert(apr_add_device(&parent,&node,7,2)==-ENODATA && !router.svcs_idr && !allocations && registered==1);
 property_error=0; id_error=-ENOSPC;
 assert(apr_add_device(&parent,&node,7,2)==-ENOSPC && !router.svcs_idr && !allocations && registered==1);
 id_error=0; allocation_error=1;
 assert(apr_add_device(&parent,&node,7,2)==-ENOMEM && !allocations && registered==1);
 allocation_error=0;
 name_error=-ENOMEM;
 assert(apr_add_device(&parent,&node,7,2)==-ENOMEM && !allocations && !names && registered==1);
 name_error=0; router.type=99;
 assert(apr_add_device(&parent,&node,7,2)==-EINVAL && !allocations && !names && registered==1);
 for(int type=PR_TYPE_APR;type<=PR_TYPE_GPR;type++) {
  router.type=type;
  for(int optional=0;optional<2;optional++) {
   property_error=optional?-EINVAL:0;
   assert(!apr_add_device(&parent,&node,7,2) && router.svcs_idr && allocations==1);
   struct apr_device *d=router.svcs_idr->priv;
   assert(d->svc_id==7 && d->domain_id==2 && d->dev.parent==&parent);
   mutex_lock(&router.callback_lock); spin_lock(&router.svcs_lock);
   idr_remove(&router.svcs_idr,7);
   spin_unlock(&router.svcs_lock); mutex_unlock(&router.callback_lock);
   put_device(&d->dev);
   assert(!allocations && !names && !router.svcs_lock && !router.callback_lock);
  }
  register_error=-EIO;
  assert(apr_add_device(&parent,&node,7,2)==-EIO && !allocations && !names && !router.svcs_idr);
  register_error=0;
 }
 struct pkt_router_svc occupied={.id=7}; router.svcs_idr=&occupied;
 assert(apr_add_device(&parent,&node,7,2)==-ENOSPC && router.svcs_idr==&occupied && !allocations && !names);
}
C
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -fsanitize=address,undefined \
 -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check"
printf 'APR/GPR actual-source service registration, allocation, IDR and malformed/optional property cleanup passed.\n'
