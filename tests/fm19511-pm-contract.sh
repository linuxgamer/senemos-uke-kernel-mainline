#!/usr/bin/env bash
# COPR only: run the actual IRQ/status/sleep functions with explicit bus boundaries.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
awk '/^struct fm19511 \{/ {copy=1} copy {print} copy && /^};/ {exit}' "$root/src/nfc/fm19511-uke.c" > "$work/struct.inc"
awk '/^static (int|void|irqreturn_t) fm19511_(clear_irq|irq|suspend|resume)\(/ {copy=1} copy {print} copy && /^}/ {copy=0}' "$root/src/nfc/fm19511-uke.c" > "$work/functions.inc"
cat > "$work/test.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint8_t u8;typedef uint16_t u16;typedef uint64_t u64;
typedef struct { int value; } atomic_t;
typedef struct { u64 value; } atomic64_t;
typedef int irqreturn_t;typedef int wait_queue_head_t;
struct mutex { bool locked; };
struct kref { int unused; };
struct miscdevice { int unused; };
struct work_struct { int unused; };
struct delayed_work { struct work_struct work; };
struct device { int unused; };
struct i2c_client { struct device dev; void *data; };
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define container_of(p,t,m) ((t *)((char *)(p)-offsetof(t,m)))
#define to_delayed_work(p) container_of(p,struct delayed_work,work)
#define to_i2c_client(p) container_of(p,struct i2c_client,dev)
#define READ_ONCE(v) (v)
#define IRQ_HANDLED 1
#define system_wq NULL
#define msecs_to_jiffies(ms) (ms)
#include "struct.inc"
static unsigned int reads,fail_read,schedules,cancels,wakes,wake_events;
static void mutex_lock(struct mutex *m){assert(!m->locked);m->locked=true;}
static void mutex_unlock(struct mutex *m){assert(m->locked);m->locked=false;}
static void atomic_set(atomic_t *a,int v){a->value=v;}
static u64 atomic64_read(atomic64_t *a){return a->value;}
static void atomic64_inc(atomic64_t *a){a->value++;}
static void wake_up_interruptible(wait_queue_head_t *q){(void)q;wakes++;}
static void pm_wakeup_event(struct device *dev,unsigned int ms){assert(dev&&ms==2000);wake_events++;}
static void mod_delayed_work(void *queue,struct delayed_work *work,unsigned int delay)
{(void)queue;assert(work&&delay==150);schedules++;}
static void cancel_delayed_work_sync(struct delayed_work *work){assert(work);cancels++;}
static struct fm19511 *i2c_get_clientdata(struct i2c_client *client){return client->data;}
static int fm19511_read_reg(struct fm19511 *tag,u16 address,u8 *value)
{
 assert(tag->lock.locked&&!tag->suspended&&tag->client);
 reads++;if(reads==fail_read)return -EREMOTEIO;
 assert(address>=0xfff7&&address<=0xfff9);*value=address&0xff;return 0;
}
#include "functions.inc"
int main(void)
{
 struct i2c_client client={};struct fm19511 tag={.client=&client};client.data=&tag;
 assert(fm19511_irq(170,&tag)==IRQ_HANDLED&&tag.event.value&&tag.irq_sequence.value==1);
 assert(schedules==1&&wake_events==1);
 tag.event.value=0;fm19511_clear_irq(&tag.clear_irq.work);
 assert(reads==3&&tag.status_sequence==1&&!tag.fault&&tag.event.value);
 assert(tag.irq_status[0]==0xf7&&tag.irq_status[1]==0xf8&&tag.irq_status[2]==0xf9);
 tag.status_sequence=0;tag.irq_status[0]=0xa5;fail_read=reads+2;
 fm19511_clear_irq(&tag.clear_irq.work);
 assert(tag.fault==-EREMOTEIO&&tag.irq_status[0]==0xa5&&tag.status_sequence==0);
 unsigned int before=reads;
 assert(!fm19511_suspend(&client.dev)&&tag.suspended&&cancels==1);
 fm19511_clear_irq(&tag.clear_irq.work);assert(reads==before);
 assert(fm19511_irq(170,&tag)==IRQ_HANDLED&&tag.irq_sequence.value==2);
 assert(schedules==1&&wake_events==2);
 assert(!fm19511_resume(&client.dev)&&!tag.suspended&&schedules==2);
 fail_read=0;fm19511_clear_irq(&tag.clear_irq.work);
 assert(tag.status_sequence==2&&!tag.fault&&reads==before+3);
 tag.client=NULL;before=reads;fm19511_clear_irq(&tag.clear_irq.work);assert(reads==before);
 assert(wakes==7);
 puts("Actual FM19511 IRQ/status/PM: deferred raw status, partial read failure, no sleep bus access, wake events and resume passed; no physical wake test.");
}
C
${CC:-cc} ${CFLAGS:-} -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter -I "$work" "$work/test.c" -o "$work/test"
"$work/test"
