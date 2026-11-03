#!/usr/bin/env bash
# Prepared only on 2026-10-18. Runs the actual Uke coordinator/callback later.
set -Eeuo pipefail
kernel=${1:?Pass the prepared kernel source directory}
source=$kernel/drivers/power/supply/qcom_battmgr.c
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
{
cat <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <unistd.h>
#include <time.h>
typedef uint32_t u32; typedef int32_t s32; typedef uint64_t u64;
typedef uint32_t __le32; typedef uint16_t __le16; typedef uint8_t u8;
typedef pthread_mutex_t spinlock_t;
struct mutex { pthread_mutex_t lock; };
struct completion { pthread_mutex_t lock; pthread_cond_t ready; int done; };
struct device { void *data; }; struct power_supply { int unused; };
struct work_struct { int unused; }; struct pmic_glink_client { int unused; };
#define HZ 1000
#define NSEC_PER_SEC 1000000000ULL
#ifndef CONFIG_BATTERY_QCOM_BATTMGR_UKE_THRESHOLDS
#define CONFIG_BATTERY_QCOM_BATTMGR_UKE_THRESHOLDS 0
#endif
#ifndef CONFIG_BATTERY_QCOM_BATTMGR_UKE_CURRENT
#define CONFIG_BATTERY_QCOM_BATTMGR_UKE_CURRENT 0
#endif
#define IS_ENABLED(x) (x)
struct pid { int unused; };
static struct pid owner;
#define current NULL
#define GLOBAL_ROOT_UID 0
#define uid_eq(a,b) ((a)==(b))
static struct pid *task_tgid(void *task) { (void)task; return &owner; }
static unsigned int current_euid(void) { return 0; }
static unsigned long jiffies;
#define time_before(a,b) ((long)((a)-(b))<0)
#define time_after_eq(a,b) (!time_before(a,b))
#define spin_lock_irqsave(l,f) ((f)=0,pthread_mutex_lock(l))
#define spin_unlock_irqrestore(l,f) ((void)(f),pthread_mutex_unlock(l))
#define READ_ONCE(x) (x)
#define WRITE_ONCE(x,v) ((x)=(v))
#define cpu_to_le32(x) ((u32)(x))
#define le32_to_cpu(x) ((u32)(x))
#define dev_err(...) ((void)0)
#define lockdep_assert_held(l) ((void)(l))
#define container_of(p,t,m) ((t *)((char *)(p)-offsetof(t,m)))
#define SERVREG_SERVICE_STATE_UP 1
#define SERVREG_SERVICE_STATE_DOWN 0
static _Thread_local bool pm_thread;
static pthread_mutex_t gate = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gate_changed = PTHREAD_COND_INITIALIZER;
static bool request_blocked, release_request, pm_lock_attempted;
static void mutex_lock(struct mutex *m) {
 if(pm_thread) {
  pthread_mutex_lock(&gate); pm_lock_attempted=true;
  pthread_cond_broadcast(&gate_changed); pthread_mutex_unlock(&gate);
 }
 assert(!pthread_mutex_lock(&m->lock));
}
static void mutex_unlock(struct mutex *m) { assert(!pthread_mutex_unlock(&m->lock)); }
static void reinit_completion(struct completion *c) { pthread_mutex_lock(&c->lock); c->done=0; pthread_mutex_unlock(&c->lock); }
static void complete(struct completion *c) { pthread_mutex_lock(&c->lock); c->done++; pthread_cond_broadcast(&c->ready); pthread_mutex_unlock(&c->lock); }
static unsigned long wait_for_completion_timeout(struct completion *c, unsigned long timeout) {
 struct timespec end; clock_gettime(CLOCK_REALTIME,&end); end.tv_sec++;
 pthread_mutex_lock(&c->lock);
 int ret=0;
 while(!c->done && !ret) ret=pthread_cond_timedwait(&c->ready,&c->lock,&end);
 unsigned long done=c->done?timeout:0;
 if(c->done)c->done--;
 pthread_mutex_unlock(&c->lock); return done;
}
static uint64_t ktime_get_boottime_ns(void) { return 42; }
static void schedule_work(struct work_struct *w) { (void)w; }
static void cancel_work_sync(struct work_struct *w) { (void)w; }
static void *dev_get_drvdata(struct device *dev) { return dev->data; }
C
awk '/^#define PMIC_GLINK_/ {print}
 /^struct pmic_glink_hdr/ {emit=1} emit {print} emit && /^};/ {emit=0}' "$kernel/include/linux/soc/qcom/pmic_glink.h"
awk '/^#define BATTMGR_CHEMISTRY_LEN/ {emit=1}
 /^static void qcom_battmgr_sm8350_callback\(/ {emit=0} emit {print}' "$source"
cat <<'C'
static void qcom_battmgr_uke_callback(struct qcom_battmgr *,const struct qcom_battmgr_message *,size_t);
static void qcom_battmgr_pdr_notify(void *,int);
static struct qcom_battmgr *active;
static int mode, sends, decodes;
static void qcom_battmgr_sm8350_callback(struct qcom_battmgr *b,const struct qcom_battmgr_message *m,size_t len) {
 assert(len==sizeof(m->hdr)+sizeof(m->intval));
 if(m->hdr.opcode==BATTMGR_USB_PROPERTY_SET) return;
 decodes++; b->status.current_now=m->intval.value;
}
static void qcom_battmgr_notification(struct qcom_battmgr *b,const struct qcom_battmgr_message *m,int len) { (void)b;(void)m;(void)len; }
static int pmic_glink_send(struct pmic_glink_client *client, void *data, size_t len) {
 (void)client; (void)len; sends++;
 struct qcom_battmgr_property_request *q=data;
 if(q->hdr.opcode==BATTMGR_REQUEST_NOTIFICATION) {
  usleep(1000); struct qcom_battmgr_message ack={.hdr=q->hdr};
  qcom_battmgr_uke_callback(active,&ack,sizeof(ack.hdr)); return 0;
 }
 if(q->hdr.opcode==BATTMGR_CHG_CTRL_LIMIT_EN) {
  struct qcom_battmgr_message ack={.hdr=q->hdr};
  if(mode==11)return 0; /* Dispatcher drops a truncated header. */
  if(mode==12)ack.hdr.owner++; /* Foreign response must time out. */
  qcom_battmgr_uke_callback(active,&ack,mode==10?sizeof(ack)+4:sizeof(ack.hdr)+(mode==9?0:4)); return 0;
 }
 if(mode==1) return 0; /* Timeout: no reply. */
 if(mode==7) return -EIO; /* Delivery is ambiguous, including for SET. */
 if(mode==2) { qcom_battmgr_pdr_notify(active,SERVREG_SERVICE_STATE_DOWN); return 0; }
 if(mode==13) {
  pthread_mutex_lock(&gate); request_blocked=true;
  pthread_cond_broadcast(&gate_changed);
  while(!release_request) pthread_cond_wait(&gate_changed,&gate);
  pthread_mutex_unlock(&gate);
 }
 struct qcom_battmgr_message r={.hdr=q->hdr}; r.intval.property=q->property; r.intval.value=123;
 if(mode==3) r.intval.result=EPERM;
 const size_t size=sizeof(r.hdr)+sizeof(r.intval);
 if(mode==4) {
  r.hdr.owner++; qcom_battmgr_uke_callback(active,&r,size); r.hdr.owner--;
  r.hdr.type++; qcom_battmgr_uke_callback(active,&r,size); r.hdr.type--;
  r.hdr.opcode++; qcom_battmgr_uke_callback(active,&r,size); r.hdr.opcode--;
  r.intval.property++; qcom_battmgr_uke_callback(active,&r,size); r.intval.property--;
  assert(!active->transaction.response_len);
 }
 if(mode==5) {
  qcom_battmgr_uke_callback(active,&r,size-4); return 0;
 }
 if(mode==6) {
  struct qcom_battmgr_message n={.hdr={.owner=PMIC_GLINK_OWNER_BATTMGR,.type=PMIC_GLINK_NOTIFY,.opcode=BATTMGR_NOTIFICATION}};
  n.notification=NOTIF_USB_PROPERTY;
  qcom_battmgr_uke_callback(active,&n,sizeof(n.hdr)+sizeof(n.notification));
 }
 qcom_battmgr_uke_callback(active,&r,size);
 if(mode==8) { r.intval.value=9999; qcom_battmgr_uke_callback(active,&r,size); }
 return 0;
}
C
for name in uke_control_live uke_generation uke_battery_property uke_request request uke_callback enable_worker pdr_notify suspend resume; do
 awk -v name="qcom_battmgr_$name" '$0 ~ "^static (int|void|u32|bool) " name "\\(" {emit=1}
 emit {print} emit && /^}/ {exit}' "$source"
done
cat <<'C'
static void initialize(struct qcom_battmgr *b) {
 memset(b,0,sizeof(*b)); b->variant=QCOM_BATTMGR_UKE; b->service_up=true;
 pthread_mutex_init(&b->lock.lock,NULL); pthread_mutex_init(&b->transaction.lock,NULL);
 pthread_mutex_init(&b->ack.lock,NULL); pthread_cond_init(&b->ack.ready,NULL);
 active=b; mode=0;
}
static int get(struct qcom_battmgr *b, unsigned opcode) {
 struct qcom_battmgr_property_request q={.hdr={.owner=PMIC_GLINK_OWNER_BATTMGR,.type=PMIC_GLINK_REQ_RESP,.opcode=opcode},.property=opcode==BATTMGR_USB_PROPERTY_SET?USB_INPUT_CURR_LIMIT:13};
 mutex_lock(&b->lock); int ret=qcom_battmgr_uke_request(b,&q,sizeof(q)); mutex_unlock(&b->lock); return ret;
}
static void *reader(void *arg) { for(int i=0;i<20;i++)assert(!get(arg,BATTMGR_BAT_PROPERTY_GET)); return NULL; }
static void *enabler(void *arg) { struct qcom_battmgr *b=arg; for(int i=0;i<20;i++)qcom_battmgr_enable_worker(&b->enable_work); return NULL; }
static void *pending_reader(void *arg) { assert(!get(arg,BATTMGR_BAT_PROPERTY_GET)); return NULL; }
static void *suspender(void *arg) { pm_thread=true; assert(!qcom_battmgr_suspend(arg)); return NULL; }
int main(void) {
 struct qcom_battmgr b; initialize(&b);
 assert(!get(&b,BATTMGR_BAT_PROPERTY_GET) && b.status.current_now==123);
 mode=4; assert(!get(&b,BATTMGR_BAT_PROPERTY_GET));
 mode=3; int before=decodes;
 assert(get(&b,BATTMGR_BAT_PROPERTY_GET)==-EREMOTEIO && b.transaction.raw_result==EPERM && decodes==before);
 mode=6; assert(get(&b,BATTMGR_BAT_PROPERTY_GET)==-EAGAIN && decodes==before);
 assert(get(&b,BATTMGR_USB_PROPERTY_SET)==-ESTALE && decodes==before);
 mode=2; assert(get(&b,BATTMGR_BAT_PROPERTY_GET)==-ECONNRESET);
 qcom_battmgr_pdr_notify(&b,SERVREG_SERVICE_STATE_UP);
 before=sends; assert(get(&b,BATTMGR_BAT_PROPERTY_GET)==-EPIPE && sends==before);
 struct qcom_battmgr c; initialize(&c); mode=1;
 assert(get(&c,BATTMGR_BAT_PROPERTY_GET)==-ETIMEDOUT);
 before=sends; assert(get(&c,BATTMGR_BAT_PROPERTY_GET)==-EPIPE && sends==before);
 struct qcom_battmgr_message late={.hdr={.owner=PMIC_GLINK_OWNER_BATTMGR,.type=PMIC_GLINK_REQ_RESP,.opcode=BATTMGR_BAT_PROPERTY_GET}};
 late.intval.property=13; qcom_battmgr_uke_callback(&c,&late,sizeof(late.hdr)+sizeof(late.intval));
 assert(!c.status.current_now);
 struct qcom_battmgr d; initialize(&d); mode=5;
 assert(get(&d,BATTMGR_BAT_PROPERTY_GET)==-EPROTO && d.transaction.desynced);
 struct qcom_battmgr e; initialize(&e); e.transaction.suspended=true;
 assert(get(&e,BATTMGR_BAT_PROPERTY_GET)==-EHOSTDOWN);
 e.transaction.suspended=false; e.transaction.removing=true;
 assert(get(&e,BATTMGR_BAT_PROPERTY_GET)==-ENODEV);
 struct qcom_battmgr sleep; initialize(&sleep); mode=13;
 struct device dev={.data=&sleep}; pthread_t reading, suspending;
 assert(!pthread_create(&reading,NULL,pending_reader,&sleep));
 pthread_mutex_lock(&gate);
 while(!request_blocked) pthread_cond_wait(&gate_changed,&gate);
 pthread_mutex_unlock(&gate);
 assert(!pthread_create(&suspending,NULL,suspender,&dev));
 pthread_mutex_lock(&gate);
 while(!pm_lock_attempted) pthread_cond_wait(&gate_changed,&gate);
 pthread_mutex_unlock(&gate);
 pthread_mutex_lock(&sleep.transaction.lock);
 assert(sleep.transaction.pending && !sleep.transaction.suspended &&
        !sleep.transaction.desynced && sleep.transaction.generation==0);
 pthread_mutex_unlock(&sleep.transaction.lock);
 pthread_mutex_lock(&gate); release_request=true;
 pthread_cond_broadcast(&gate_changed); pthread_mutex_unlock(&gate);
 assert(!pthread_join(reading,NULL)); assert(!pthread_join(suspending,NULL));
 assert(sleep.transaction.suspended && !sleep.transaction.pending &&
        !sleep.transaction.desynced && sleep.transaction.generation==1);
 before=sends; assert(get(&sleep,BATTMGR_BAT_PROPERTY_GET)==-EHOSTDOWN && sends==before);
 assert(!qcom_battmgr_resume(&dev)); mode=0;
 assert(!get(&sleep,BATTMGR_BAT_PROPERTY_GET));
 struct qcom_battmgr inconsistent; initialize(&inconsistent);
 inconsistent.transaction.pending=true; struct device baddev={.data=&inconsistent};
 assert(qcom_battmgr_suspend(&baddev)==-EBUSY);
 assert(inconsistent.transaction.pending && !inconsistent.transaction.suspended &&
        !inconsistent.transaction.desynced && !inconsistent.transaction.generation);
 dev.data=&c; assert(!qcom_battmgr_suspend(&dev)); assert(!qcom_battmgr_resume(&dev));
 before=sends; assert(get(&c,BATTMGR_BAT_PROPERTY_GET)==-EPIPE && sends==before);
 struct qcom_battmgr other; initialize(&other); other.variant=QCOM_BATTMGR_SM8550;
 other.transaction.pending=true; dev.data=&other;
 assert(!qcom_battmgr_suspend(&dev)); assert(!qcom_battmgr_resume(&dev));
 assert(other.transaction.pending && !other.transaction.suspended &&
        !other.transaction.generation && !other.transaction.desynced);
 struct qcom_battmgr f; initialize(&f);
 pthread_t readers[3]; assert(!pthread_create(&readers[0],NULL,reader,&f));
 assert(!pthread_create(&readers[1],NULL,reader,&f)); assert(!pthread_create(&readers[2],NULL,enabler,&f));
 for(int i=0;i<3;i++)assert(!pthread_join(readers[i],NULL));
 struct qcom_battmgr g; initialize(&g); mode=7;
 assert(get(&g,BATTMGR_USB_PROPERTY_SET)==-EIO && g.transaction.desynced);
 before=sends; assert(get(&g,BATTMGR_USB_PROPERTY_SET)==-EPIPE && sends==before);
 struct qcom_battmgr h; initialize(&h); mode=8;
 assert(!get(&h,BATTMGR_USB_PROPERTY_SET));
 struct qcom_battmgr_property_request budget={.hdr={.owner=PMIC_GLINK_OWNER_BATTMGR,.type=PMIC_GLINK_REQ_RESP,.opcode=BATTMGR_USB_PROPERTY_SET},.property=USB_INPUT_CURR_LIMIT,.value=500000};
 h.protection.wet_latched=true;before=sends;
 mutex_lock(&h.lock);
 assert(qcom_battmgr_uke_request(&h,&budget,sizeof(budget))==-EACCES&&sends==before);
 mutex_unlock(&h.lock);h.protection.wet_latched=false;
 /* An ACK is not effective-current readback; it must not mutate GET data. */
 assert(!h.status.current_now);
 assert(!get(&h,BATTMGR_BAT_PROPERTY_GET) && h.status.current_now==123);
 mode=0;
 struct qcom_battmgr_message storm={.hdr={.owner=PMIC_GLINK_OWNER_BATTMGR,.type=PMIC_GLINK_NOTIFY,.opcode=BATTMGR_NOTIFICATION}};
 storm.notification=NOTIF_USB_PROPERTY;
 before=sends;
 u32 request_generation=qcom_battmgr_uke_generation(&h);
 for(int i=0;i<10000;i++) qcom_battmgr_uke_callback(&h,&storm,sizeof(storm.hdr)+sizeof(storm.notification));
 assert(sends==before && h.transaction.source_generation==10000 && !h.transaction.pending);
 assert(qcom_battmgr_uke_generation(&h)==request_generation+10000u);
 assert(!get(&h,BATTMGR_BAT_PROPERTY_GET));
 before=sends;
 assert(get(&h,UKE_INPUT_SUSPEND_GET)==-EACCES && sends==before);
 assert(get(&h,UKE_INPUT_SUSPEND_SET)==-EACCES && sends==before);
 assert(get(&h,0x31)==(IS_ENABLED(CONFIG_BATTERY_QCOM_BATTMGR_UKE_THRESHOLDS)?-EACCES:-EOPNOTSUPP) && sends==before);
#if CONFIG_BATTERY_QCOM_BATTMGR_UKE_THRESHOLDS
 struct qcom_battmgr pre; initialize(&pre);
 struct qcom_battmgr_property_request cap={.hdr={.owner=PMIC_GLINK_OWNER_BATTMGR,.type=PMIC_GLINK_REQ_RESP,.opcode=BATTMGR_BAT_PROPERTY_SET},.property=25,.value=1};
 pre.control.preconfigured_enable=true;
 pre.control.preconfigured_generation=pre.transaction.generation;
 mutex_lock(&pre.lock);
 assert(!qcom_battmgr_uke_request(&pre,&cap,sizeof(cap)));
 before=sends;cap.value=0;
 assert(qcom_battmgr_uke_request(&pre,&cap,sizeof(cap))==-EACCES && sends==before);
 cap.value=1;cap.property=12;
 assert(qcom_battmgr_uke_request(&pre,&cap,sizeof(cap))==-EACCES && sends==before);
 cap.property=25;pre.control.preconfigured_generation++;
 assert(qcom_battmgr_uke_request(&pre,&cap,sizeof(cap))==-EACCES && sends==before);
 pre.control.preconfigured_generation=pre.transaction.generation;
 pre.control.preconfigured_enable=false;
 assert(qcom_battmgr_uke_request(&pre,&cap,sizeof(cap))==-EACCES && sends==before);
 mutex_unlock(&pre.lock);
 struct qcom_battmgr fixed; initialize(&fixed);
 fixed.control.preconfigured_apply=true;
 fixed.control.preconfigured_uncertain=true;
 fixed.control.preconfigured_limit_attempted=true;
 fixed.control.preconfigured_generation=fixed.transaction.generation;
 struct qcom_battmgr_charge_ctrl_request fixed_limit={.hdr={.owner=PMIC_GLINK_OWNER_BATTMGR,.type=PMIC_GLINK_REQ_RESP,.opcode=BATTMGR_CHG_CTRL_LIMIT_EN},.enable=1,.target_soc=80,.delta_soc=10};
 mutex_lock(&fixed.lock);
 mode=9;assert(!qcom_battmgr_uke_request(&fixed,&fixed_limit,sizeof(fixed_limit)));
 assert(fixed.transaction.response_len==sizeof(struct pmic_glink_hdr));
 assert(fixed.control.preconfigured_uncertain && !fixed.control.verified && !fixed.control.ack_bytes);
 mode=0;assert(!qcom_battmgr_uke_request(&fixed,&fixed_limit,sizeof(fixed_limit)));
 assert(fixed.transaction.response_len==sizeof(struct pmic_glink_hdr)+4 && fixed.control.preconfigured_uncertain);
 before=sends;
 fixed_limit.enable=0;assert(qcom_battmgr_uke_request(&fixed,&fixed_limit,sizeof(fixed_limit))==-EACCES && sends==before);
 fixed_limit.enable=1;fixed_limit.target_soc=81;
 assert(qcom_battmgr_uke_request(&fixed,&fixed_limit,sizeof(fixed_limit))==-EACCES && sends==before);
 fixed_limit.target_soc=80;fixed_limit.delta_soc=5;
 assert(qcom_battmgr_uke_request(&fixed,&fixed_limit,sizeof(fixed_limit))==-EACCES && sends==before);
 fixed_limit.delta_soc=10;fixed_limit.hdr.owner++;
 assert(qcom_battmgr_uke_request(&fixed,&fixed_limit,sizeof(fixed_limit))==-EACCES && sends==before);
 fixed_limit.hdr.owner--;fixed_limit.hdr.type++;
 assert(qcom_battmgr_uke_request(&fixed,&fixed_limit,sizeof(fixed_limit))==-EACCES && sends==before);
 fixed_limit.hdr.type--;fixed.control.preconfigured_generation++;
 assert(qcom_battmgr_uke_request(&fixed,&fixed_limit,sizeof(fixed_limit))==-EACCES && sends==before);
 fixed.control.preconfigured_generation=fixed.transaction.generation;
 assert(qcom_battmgr_uke_request(&fixed,&fixed_limit,sizeof(fixed_limit)-4)==-EINVAL && sends==before);
 mutex_unlock(&fixed.lock);
 for(int fault=10;fault<=12;fault++) {
  struct qcom_battmgr rejected;initialize(&rejected);mode=fault;
  rejected.control.preconfigured_apply=rejected.control.preconfigured_uncertain=true;
  rejected.control.preconfigured_limit_attempted=true;
  rejected.control.preconfigured_generation=rejected.transaction.generation;
  mutex_lock(&rejected.lock);
  assert(qcom_battmgr_uke_request(&rejected,&fixed_limit,sizeof(fixed_limit))<0);
  assert(rejected.transaction.desynced && rejected.control.preconfigured_uncertain);
  before=sends;
  assert(qcom_battmgr_uke_request(&rejected,&fixed_limit,sizeof(fixed_limit))==-EPIPE && sends==before);
  mutex_unlock(&rejected.lock);
 }
 mode=0;
 struct qcom_battmgr ctrl; initialize(&ctrl);
 ctrl.transaction.instance_ns=1;
 ctrl.control.owner=&owner; ctrl.control.expires_ns=100; ctrl.control.reviewed_ns=41;
 ctrl.control.instance_ns=1; ctrl.control.current_admitted=true;
 ctrl.control.current_min_ua=100; ctrl.control.current_max_ua=1000;
 ctrl.control.measurement_ns=42; ctrl.control.measurement_generation=ctrl.transaction.generation;
 ctrl.control.ack_bytes=sizeof(struct pmic_glink_hdr);
 struct qcom_battmgr_property_request set={.hdr={.owner=PMIC_GLINK_OWNER_BATTMGR,.type=PMIC_GLINK_REQ_RESP,.opcode=BATTMGR_BAT_PROPERTY_SET},.property=12,.value=500};
 mutex_lock(&ctrl.lock);
 assert(!qcom_battmgr_uke_request(&ctrl,&set,sizeof(set)));
 set.value=0; before=sends; assert(qcom_battmgr_uke_request(&ctrl,&set,sizeof(set))==-EOPNOTSUPP && sends==before);
 set.value=UINT_MAX; assert(qcom_battmgr_uke_request(&ctrl,&set,sizeof(set))==-EOPNOTSUPP && sends==before);
 set.value=500; set.property=10; assert(qcom_battmgr_uke_request(&ctrl,&set,sizeof(set))==-EOPNOTSUPP && sends==before);
 set.property=25; set.value=1; assert(qcom_battmgr_uke_request(&ctrl,&set,sizeof(set))==-EOPNOTSUPP && sends==before);
 ctrl.control.may_enable=true; assert(!qcom_battmgr_uke_request(&ctrl,&set,sizeof(set)));
 struct qcom_battmgr_property_request protection={.hdr={.owner=PMIC_GLINK_OWNER_BATTMGR,.type=PMIC_GLINK_REQ_RESP,.opcode=BATTMGR_USB_PROPERTY_SET},.property=USB_MOISTURE_EN,.value=1};
 before=sends;assert(qcom_battmgr_uke_request(&ctrl,&protection,sizeof(protection))==-EACCES&&sends==before);
 ctrl.control.moisture_enabling=true;ctrl.control.moisture_generation=ctrl.transaction.generation;
 assert(!qcom_battmgr_uke_request(&ctrl,&protection,sizeof(protection)));
 before=sends;protection.value=0;assert(qcom_battmgr_uke_request(&ctrl,&protection,sizeof(protection))==-EACCES&&sends==before);
 protection.value=1;protection.hdr.owner++;assert(qcom_battmgr_uke_request(&ctrl,&protection,sizeof(protection))==-EACCES&&sends==before);
 protection.hdr.owner--;ctrl.control.moisture_enabling=false;
 protection.hdr.opcode=UKE_INPUT_SUSPEND_SET;protection.property=UKE_INPUT_SUSPEND_PROPERTY;
 assert(qcom_battmgr_uke_request(&ctrl,&protection,sizeof(protection))==-EACCES&&sends==before);
 ctrl.control.safety_request=true;assert(!qcom_battmgr_uke_request(&ctrl,&protection,sizeof(protection)));
 before=sends;protection.value=2;assert(qcom_battmgr_uke_request(&ctrl,&protection,sizeof(protection))==-EACCES&&sends==before);
 protection.value=1;protection.property++;assert(qcom_battmgr_uke_request(&ctrl,&protection,sizeof(protection))==-EACCES&&sends==before);
 protection.property--;protection.hdr.opcode=UKE_INPUT_SUSPEND_GET;
 assert(qcom_battmgr_uke_request(&ctrl,&protection,sizeof(protection))==-ENODATA); // Synthetic 123 is not boolean.
 ctrl.control.safety_request=false;
 ctrl.control.invalidation_ns=42; before=sends;
 assert(qcom_battmgr_uke_request(&ctrl,&set,sizeof(set))==-EACCES && sends==before);
 ctrl.control.invalidation_ns=0; ctrl.control.measurement_generation++;
 assert(qcom_battmgr_uke_request(&ctrl,&set,sizeof(set))==-ESTALE && sends==before);
 ctrl.control.measurement_generation=ctrl.transaction.generation;
 set.hdr.opcode=BATTMGR_BAT_PROPERTY_GET; set.property=12;
 assert(!qcom_battmgr_uke_request(&ctrl,&set,sizeof(set)) && ctrl.control.current_ua==123);
 struct qcom_battmgr_charge_ctrl_request limit={.hdr={.owner=PMIC_GLINK_OWNER_BATTMGR,.type=PMIC_GLINK_REQ_RESP,.opcode=BATTMGR_CHG_CTRL_LIMIT_EN},.enable=1,.target_soc=80,.delta_soc=10};
 mode=9; assert(!qcom_battmgr_uke_request(&ctrl,&limit,sizeof(limit)));
 assert(!ctrl.control.verified); /* Opaque ACK alone cannot prove applied state. */
 mode=0; assert(qcom_battmgr_uke_request(&ctrl,&limit,sizeof(limit))==-EPROTO && ctrl.transaction.desynced);
 before=sends; assert(qcom_battmgr_uke_request(&ctrl,&limit,sizeof(limit))==-EPIPE && sends==before);
 mutex_unlock(&ctrl.lock);
#endif
 return 0;
}
C
} > "$work/coordinator.c"
control=${UKE_TEST_CONTROL:-0}
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -pthread \
    -DCONFIG_BATTERY_QCOM_BATTMGR_UKE_THRESHOLDS="$control" \
    -DCONFIG_BATTERY_QCOM_BATTMGR_UKE_CURRENT="$control" "$work/coordinator.c" -o "$work/coordinator"
"$work/coordinator"
printf '%s\n' 'Actual Uke request matching, error, late reply, generation, PDR, concurrent enable/read and suspend-drain contract passed; no physical result'
