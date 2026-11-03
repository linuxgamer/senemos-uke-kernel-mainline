#!/usr/bin/env bash
# Exercise actual service removal and the native GPR quiesce boundary.
set -euo pipefail
kernel=${1:?Pass prepared kernel tree}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <errno.h>
#define WRITE_ONCE(p,v) ((p)=(v))
#define EXPORT_SYMBOL_GPL(x)
struct mutex{bool held;};
static void mutex_lock(struct mutex *m){assert(!m->held);m->held=true;}
static void mutex_unlock(struct mutex *m){assert(m->held);m->held=false;}
#define spin_lock(p) mutex_lock(p)
#define spin_unlock(p) mutex_unlock(p)
#define PR_TYPE_APR 0
#define PR_TYPE_GPR 1
struct device{struct device *parent;void *data,*driver;};
struct apr_device;
struct apr_driver{void (*remove)(struct apr_device*);int (*probe)(struct apr_device*);void *gpr_callback;};
struct service{void *callback;int id;};
struct apr_device{struct device dev;struct service svc;};
typedef struct apr_device gpr_device_t;
struct packet_router{struct mutex svcs_lock,callback_lock;struct service *svcs_idr;int type;};
static struct apr_device *to_apr_device(struct device *d){return (void*)d;}
static struct apr_driver *to_apr_driver(void *d){return d;}
static void *dev_get_drvdata(struct device *d){return d->data;}
static struct packet_router router;
static int removes;
static int probe_error;
static int driver_probe(struct apr_device *d){assert(d);return probe_error;}
static void idr_remove(struct service **p,int id){
 assert(router.svcs_lock.held && *p && (*p)->id==id);
 if(router.type==PR_TYPE_GPR && !router.callback_lock.held)fprintf(stderr,"Static GPR service removed without draining its callback lookup\n");
 assert(router.type!=PR_TYPE_GPR || router.callback_lock.held);*p=NULL;
}
static void driver_remove(struct apr_device *d){assert(d);removes++;}
C
awk '/^void gpr_quiesce_service\(/ {print "#define HAVE_QUIESCE 1";emit=1}
 /^static void apr_device_remove\(/ {emit=1}
 /^static int apr_device_probe\(/ {emit=1}
 emit {print} emit && /^}/ {emit=0}' "$kernel/drivers/soc/qcom/apr.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
int main(void){
 struct device parent={.data=&router};struct apr_driver driver={.remove=driver_remove,.probe=driver_probe};driver.gpr_callback=&driver;
 struct apr_device dev={.dev={.parent=&parent,.driver=&driver},.svc={.callback=&driver,.id=1}};
 router.type=PR_TYPE_GPR;router.svcs_idr=&dev.svc;
 dev.svc.callback=NULL;probe_error=-EIO;assert(apr_device_probe(&dev.dev)==-EIO && !dev.svc.callback);
 probe_error=0;assert(apr_device_probe(&dev.dev)==0 && dev.svc.callback==&driver && !router.callback_lock.held);
 apr_device_remove(&dev.dev);assert(removes==1 && !router.svcs_idr && !dev.svc.callback && !router.callback_lock.held && !router.svcs_lock.held);
#ifdef HAVE_QUIESCE
 dev.svc.callback=&driver;router.svcs_idr=&dev.svc;
 gpr_quiesce_service(&dev);assert(router.svcs_idr==&dev.svc && !dev.svc.callback && !router.callback_lock.held);
 gpr_quiesce_service(&dev);assert(!router.callback_lock.held);
#endif
 router.type=PR_TYPE_APR;dev.svc.callback=&driver;router.svcs_idr=&dev.svc;
 apr_device_remove(&dev.dev);assert(removes==2 && !router.svcs_idr && !router.svcs_lock.held && !router.callback_lock.held);
}
C
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check"
printf 'GPR actual-source service quiesce, lookup drain, removal and legacy APR fixtures passed.\n'
