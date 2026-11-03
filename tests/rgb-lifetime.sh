#!/usr/bin/env bash
# Exercise actual ioctl/open/release code with host-only kernel primitive stubs.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
cat > "$stage/test.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <stddef.h>
#include <string.h>
#include "uke-rgb-policy.h"
typedef __u64 u64;
typedef __u32 u32;
#define __user
#define FMODE_READ 1
#define FMODE_WRITE 2
#define container_of(p,t,m) ((t*)((char*)(p)-offsetof(t,m)))
#define check_add_overflow(a,b,p) __builtin_add_overflow(a,b,p)
struct kref {unsigned refs;};
struct mutex {unsigned locked;};
struct inode {unsigned unused;};
struct led_classdev;
struct led_classdev_mc;
struct miscdevice {unsigned unused;};
struct delayed_work {unsigned unused;};
struct notifier_block {unsigned unused;};
struct file {void* private_data;unsigned f_mode;};
static u64 clock_ms;
static unsigned scheduled,freed;
static bool copy_failure;
static void* system_freezable_wq;
static void mutex_lock(struct mutex* m){assert(!m->locked);m->locked=1;}
static void mutex_unlock(struct mutex* m){assert(m->locked);m->locked=0;}
static bool kref_get_unless_zero(struct kref* r){if(!r->refs)return false;++r->refs;return true;}
static void kref_put(struct kref* r,void (*release)(struct kref*)){assert(r->refs);if(!--r->refs){++freed;release(r);}}
static int nonseekable_open(struct inode* i,struct file* f){(void)i;(void)f;return 0;}
static unsigned long copy_from_user(void* to,const void* from,size_t n){if(copy_failure)return n;memcpy(to,from,n);return 0;}
static unsigned long copy_to_user(void* to,const void* from,size_t n){if(copy_failure)return n;memcpy(to,from,n);return 0;}
static void mod_delayed_work(void* queue,struct delayed_work* work,unsigned delay){(void)queue;(void)work;assert(!delay);++scheduled;}
static u64 now_ms(void){return clock_ms;}
C
awk '/^struct uke_rgb \{/ {copy=1} copy {print} copy && /^};/ {exit}' "$root/src/leds/leds-uke-rgb.c" >> "$stage/test.c"
printf 'static void free_rgb(struct kref* ref){free(container_of(ref,struct uke_rgb,ref));}\n' >> "$stage/test.c"
for function in selected rgb_open rgb_release rgb_ioctl; do
    awk -v name="$function" '$0 ~ "^static .* "name"\\(" {copy=1} copy {print} copy && /^}/ {exit}' "$root/src/leds/leds-uke-rgb.c" >> "$stage/test.c"
done
cat >> "$stage/test.c" <<'C'
int main(void) {
    struct uke_rgb* rgb=calloc(1,sizeof(*rgb));assert(rgb);
    rgb->ref.refs=1;rgb->active=true;rgb->battery_soc=-1;
    struct inode inode={0};struct file writer={&rgb->misc,FMODE_READ|FMODE_WRITE};
    struct file other={&rgb->misc,FMODE_WRITE},reader={&rgb->misc,FMODE_READ};
    assert(!rgb_open(&inode,&writer) && rgb->ref.refs==2 && rgb->writer_open);
    assert(rgb_open(&inode,&other)==-EBUSY && rgb->ref.refs==2);
    assert(!rgb_open(&inode,&reader) && rgb->ref.refs==3);
    struct uke_rgb_color color={UKE_RGB_ABI,0xffff00,100,0};
    assert(rgb_ioctl(&reader,UKE_RGB_SET,(unsigned long)&color)==-EBADF);
    assert(rgb_ioctl(&writer,0,(unsigned long)&color)==-ENOTTY && !scheduled);
    for(unsigned i=0;i<4;++i) {
        struct uke_rgb_color bad=color;
        if(i==0)bad.abi=99;if(i==1)bad.rgb=0x1000000;
        if(i==2)bad.brightness_percent=101;if(i==3)bad.reserved=1;
        assert(rgb_ioctl(&writer,UKE_RGB_SET,(unsigned long)&bad)==-EINVAL && !rgb->manual && !scheduled);
    }
    copy_failure=true;assert(rgb_ioctl(&writer,UKE_RGB_SET,(unsigned long)&color)==-EFAULT);copy_failure=false;
    assert(!rgb_ioctl(&writer,UKE_RGB_SET,(unsigned long)&color) && rgb->manual && scheduled==1);
    struct uke_rgb_status s;
    assert(!rgb_ioctl(&reader,UKE_RGB_STATUS,(unsigned long)&s));
    assert(s.abi==1 && s.mode==UKE_RGB_MANUAL && s.requested_rgb==0xffff00 && s.brightness_limit==8);
    clock_ms=100;assert(!rgb_ioctl(&writer,UKE_RGB_TEST_COLORS,0) && rgb->test_until_ms==10100);
    assert(rgb_ioctl(&writer,UKE_RGB_TEST_COLORS,0)==-EBUSY && rgb->test_until_ms==10100);
    clock_ms=10099;assert(selected(rgb,clock_ms)==UKE_RGB_TEST);
    clock_ms=10100;assert(selected(rgb,clock_ms)==UKE_RGB_MANUAL);
    rgb->camera=true;assert(rgb_ioctl(&writer,UKE_RGB_TEST_COLORS,0)==-EBUSY);rgb->camera=false;
    rgb->suspended=true;assert(rgb_ioctl(&writer,UKE_RGB_TEST_COLORS,0)==-EBUSY);rgb->suspended=false;
    clock_ms=UINT64_MAX-1;assert(rgb_ioctl(&writer,UKE_RGB_TEST_COLORS,0)==-EOVERFLOW);
    assert(!rgb_ioctl(&writer,UKE_RGB_AUTOMATIC,0) && !rgb->manual && !rgb->test_until_ms);
    rgb->manual=true;assert(!rgb_release(&inode,&reader) && rgb->manual && rgb->ref.refs==2);
    rgb->test_until_ms=1000;
    unsigned previous=scheduled;
    assert(!rgb_release(&inode,&writer) && rgb->ref.refs==1 && !rgb->writer_open && !rgb->manual && !rgb->test_until_ms && scheduled==previous+1);
    writer.private_data=&rgb->misc;
    assert(!rgb_open(&inode,&writer) && rgb->ref.refs==2 && rgb->writer_open);
    rgb->dead=true;kref_put(&rgb->ref,free_rgb);assert(rgb->ref.refs==1);
    assert(rgb_ioctl(&writer,UKE_RGB_STATUS,(unsigned long)&s)==-ENODEV);
    assert(!rgb_release(&inode,&writer) && freed==1);
}
C
${CC:-cc} -std=c11 -Wall -Wextra -Werror -Wno-misleading-indentation -Wno-unused-parameter -fsanitize=address -fno-omit-frame-pointer -I "$root/src/leds" "$stage/test.c" -o "$stage/test"
"$stage/test"
printf '%s\n' 'Actual kernel RGB ioctl/open/release: copy/ABI/bounds/read-only refusals, exclusive writer, bounded test, overflow, dead-device FD lifetime: PASS (host primitives only)'
