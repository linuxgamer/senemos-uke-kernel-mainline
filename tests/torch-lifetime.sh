#!/usr/bin/env bash
# Actual request/lifecycle functions with simulated LED and kernel primitives.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
cat > "$stage/test.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include "uke-torch-uapi.h"
typedef uint32_t u32;
#define __user
#define FMODE_READ 1
#define FMODE_WRITE 2
#define LED_OFF 0
#define NOTIFY_DONE 0
#define PM_SUSPEND_PREPARE 1
#define PM_HIBERNATION_PREPARE 2
#define PM_RESTORE_PREPARE 3
#define PM_POST_SUSPEND 4
#define PM_POST_HIBERNATION 5
#define PM_POST_RESTORE 6
#define max_t(type,a,b) ((type)(a) > (type)(b) ? (type)(a) : (type)(b))
#define container_of(ptr,type,member) ((type *)((char *)(ptr) - __builtin_offsetof(type,member)))
struct kref {unsigned refs;};
struct mutex {bool locked;};
struct led_classdev {unsigned brightness,max_brightness;};
struct miscdevice {};
struct notifier_block {};
struct inode {};
struct file {void *private_data;unsigned f_mode;};
static unsigned writes,freed;
static int fail_level=-1,open_error;
static bool copy_error;
static void mutex_lock(struct mutex *m){assert(!m->locked);m->locked=true;}
static void mutex_unlock(struct mutex *m){assert(m->locked);m->locked=false;}
static void kfree(void *p){++freed;free(p);}
static bool kref_get_unless_zero(struct kref *r){if(!r->refs)return false;++r->refs;return true;}
static void kref_put(struct kref *r,void (*release)(struct kref *)){assert(r->refs);if(!--r->refs)release(r);}
static int nonseekable_open(struct inode *i,struct file *f){return open_error;}
static int led_set_brightness_sync(struct led_classdev *led,unsigned value){
    assert(value<=2);++writes;if((int)value==fail_level || fail_level==3)return -EIO;led->brightness=value;return 0;
}
static int copy_from_user(void *to,const void *from,size_t n){if(copy_error)return 1;memcpy(to,from,n);return 0;}
#define copy_to_user copy_from_user
static int notifier_from_errno(int error){return error?0x8002:1;}
C
source=$root/src/leds/leds-uke-torch.c
awk '/^struct uke_torch \{/ {copy=1} copy {print} copy && /^};/ {exit}' "$source" >> "$stage/test.c"
for name in free_torch torch_output torch_apply torch_open torch_release torch_ioctl torch_power_event torch_shutdown_event; do
    awk -v name="$name" '$0 ~ "^static .* "name"\\(" {copy=1} copy {print} copy && /^}/ {exit}' "$source" >> "$stage/test.c"
done
cat >> "$stage/test.c" <<'C'
static long request(struct file *f,unsigned cmd,unsigned value){
    struct uke_torch_request r={.abi=UKE_TORCH_ABI,.value=value};return torch_ioctl(f,cmd,(unsigned long)&r);
}
static struct uke_torch *new_torch(struct led_classdev *led){
    struct uke_torch *t=calloc(1,sizeof(*t));assert(t);t->ref.refs=1;t->active=true;t->led=led;t->requested_percent=100;return t;
}
int main(void){
    assert(sizeof(struct uke_torch_request)==16 && sizeof(struct uke_torch_status)==32);
    struct led_classdev led={.max_brightness=2};struct uke_torch *t=new_torch(&led);
    struct inode inode={};struct file writer={&t->misc,FMODE_READ|FMODE_WRITE},other={&t->misc,FMODE_WRITE},reader={&t->misc,FMODE_READ};
    assert(!torch_open(&inode,&writer) && t->writer_open && t->ref.refs==2 && !led.brightness);
    const unsigned n=writes;
    assert(torch_open(&inode,&other)==-EBUSY && writes==n && t->ref.refs==2);
    assert(!torch_open(&inode,&reader) && t->ref.refs==3);
    assert(request(&reader,UKE_TORCH_SET,50)==-EBADF && writes==n);
    assert(request(&writer,0,50)==-ENOTTY && writes==n);
    assert(request(&writer,UKE_TORCH_SET,101)==-EINVAL && request(&writer,UKE_TORCH_ENABLE,2)==-EINVAL && writes==n);
    struct uke_torch_request bad={.abi=2,.value=50};
    assert(torch_ioctl(&writer,UKE_TORCH_SET,(unsigned long)&bad)==-EINVAL);
    bad.abi=1;bad.reserved[1]=1;assert(torch_ioctl(&writer,UKE_TORCH_SET,(unsigned long)&bad)==-EINVAL);
    copy_error=true;assert(request(&writer,UKE_TORCH_SET,50)==-EFAULT && writes==n);copy_error=false;
    for(unsigned p=1;p<=100;++p){assert(!request(&writer,UKE_TORCH_SET,p));assert(t->requested_percent==p && led.brightness==(p<=50?1:2));}
    assert(!request(&writer,UKE_TORCH_SET,17) && !request(&writer,UKE_TORCH_SET,0) && !led.brightness && t->requested_percent==17);
    assert(!request(&writer,UKE_TORCH_ENABLE,1) && led.brightness==1);
    assert(!request(&writer,UKE_TORCH_ENABLE,0) && !led.brightness && t->requested_percent==17);
    fail_level=2;assert(request(&writer,UKE_TORCH_SET,100)==-EIO && !led.brightness && t->brightness_valid && t->last_io_error==-EIO && t->requested_percent==17);
    fail_level=3;assert(request(&writer,UKE_TORCH_SET,100)==-EIO && !t->brightness_valid && t->last_io_error==-EIO);fail_level=-1;
    struct uke_torch_status s;
    assert(!torch_ioctl(&reader,UKE_TORCH_STATUS,(unsigned long)&s) && s.abi==1 && !s.brightness_valid && s.last_io_error==-EIO && s.max_microamp==20000 && !s.reserved);
    copy_error=true;assert(torch_ioctl(&reader,UKE_TORCH_STATUS,(unsigned long)&s)==-EFAULT);copy_error=false;
    for(unsigned e=PM_SUSPEND_PREPARE;e<=PM_RESTORE_PREPARE;++e){
        assert(!request(&writer,UKE_TORCH_SET,100) && led.brightness==2);
        assert(torch_power_event(&t->pm_notifier,e,NULL)==1 && t->suspended && !led.brightness);
        assert(request(&writer,UKE_TORCH_ENABLE,1)==-EBUSY && !request(&writer,UKE_TORCH_ENABLE,0));
        assert(torch_power_event(&t->pm_notifier,e+3,NULL)==1 && !t->suspended && !led.brightness);
    }
    fail_level=3;assert(torch_power_event(&t->pm_notifier,PM_SUSPEND_PREPARE,NULL)==0x8002 && !t->brightness_valid);
    fail_level=-1;torch_power_event(&t->pm_notifier,PM_POST_SUSPEND,NULL);
    assert(!request(&writer,UKE_TORCH_SET,100));
    assert(!torch_release(&inode,&reader) && led.brightness==2 && t->ref.refs==2);
    assert(!torch_release(&inode,&writer) && !led.brightness && !t->writer_open && t->ref.refs==1);
    writer.private_data=&t->misc;assert(!torch_open(&inode,&writer) && t->requested_percent==100);
    assert(!request(&writer,UKE_TORCH_ENABLE,1) && led.brightness==2);
    assert(torch_shutdown_event(&t->reboot_notifier,0,NULL)==NOTIFY_DONE && t->dead && !led.brightness);
    assert(request(&writer,UKE_TORCH_SET,50)==-ENODEV);
    other.private_data=&t->misc;assert(torch_open(&inode,&other)==-ENODEV);
    kref_put(&t->ref,free_torch);const unsigned before=writes;
    assert(!torch_release(&inode,&writer) && freed==1 && writes==before);
    t=new_torch(&led);writer.private_data=&t->misc;
    open_error=-EINVAL;assert(torch_open(&inode,&writer)==-EINVAL && t->ref.refs==1 && !t->writer_open);open_error=0;
    fail_level=3;assert(torch_open(&inode,&writer)==-EIO && t->ref.refs==1 && !t->writer_open);fail_level=-1;
    t->dead=true;kref_put(&t->ref,free_torch);assert(freed==2);
}
C
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter -fsanitize=undefined -fno-sanitize-recover=all \
    -I "$root/src/leds" "$stage/test.c" -o "$stage/test"
"$stage/test"
printf '%s\n' 'Actual torch request/lifecycle functions: exclusive writer, ABI, current steps, remembered request, IO failures, sleep veto, close and late release: PASS (simulated primitives only)'
