#!/usr/bin/env bash
# Exercise the prepared multicolor store; no LED hardware or kernel module.
set -Eeuo pipefail
source=$(realpath "${1:?prepared kernel}")
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
cat > "$stage/test.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <sys/types.h>
#include <errno.h>
#define LED_COLOR_ID_MAX 32
#define LED_BLINK_SW 0
#define min(a,b) ((a)<(b)?(a):(b))
struct device_attribute {};
struct mutex {bool locked;};
struct led_classdev {struct mutex led_access;bool disabled;unsigned brightness;unsigned long work_flags;};
struct subled {unsigned intensity;};
struct led_classdev_mc {struct led_classdev led;int num_colors;struct subled subled_info[3];};
struct device {struct led_classdev_mc* led;};
static unsigned writes;
static void* dev_get_drvdata(struct device* d){return d->led;}
static struct led_classdev_mc* lcdev_to_mccdev(struct led_classdev* d){return (struct led_classdev_mc*)d;}
static void mutex_lock(struct mutex* m){assert(!m->locked);m->locked=true;}
static void mutex_unlock(struct mutex* m){assert(m->locked);m->locked=false;}
static bool led_sysfs_is_disabled(struct led_classdev* d){assert(d->led_access.locked);return d->disabled;}
static unsigned led_mc_get_max_intensity(struct led_classdev_mc* d,unsigned i){(void)d;assert(i<3);return 511;}
static bool test_bit(unsigned bit,unsigned long* flags){return *flags&(1UL<<bit);}
static void led_set_brightness(struct led_classdev* d,unsigned brightness){assert(d->led_access.locked);assert(brightness==8);++writes;}
C
awk '/^static ssize_t multi_intensity_store\(/ {copy=1} copy {print} copy && /^}/ {exit}' "$source/drivers/leds/led-class-multicolor.c" >> "$stage/test.c"
cat >> "$stage/test.c" <<'C'
int main(void) {
    struct led_classdev_mc led={.led={.disabled=true,.brightness=8},.num_colors=3};
    struct device d={&led};const char request[]="511 511 0\n";
    assert(multi_intensity_store(&d,NULL,request,sizeof(request)-1)==-EBUSY);
    assert(!writes && !led.led.led_access.locked);
    for(unsigned i=0;i<3;++i)assert(!led.subled_info[i].intensity);
    led.led.disabled=false;
    assert(multi_intensity_store(&d,NULL,request,sizeof(request)-1)==sizeof(request)-1);
    assert(writes==1 && led.subled_info[0].intensity==511 && led.subled_info[1].intensity==511 && !led.subled_info[2].intensity);
}
C
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-sign-compare -I "$source/include" "$stage/test.c" -o "$stage/test"
"$stage/test"
printf '%s\n' 'Actual multicolor sysfs store: exclusive ownership refuses intensity changes before parsing/writes; ordinary LED writes preserved: PASS (host primitives only)'
