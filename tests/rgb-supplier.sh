#!/usr/bin/env bash
# Exercise the actual probe admission; no LED writes or kernel module loads.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
source=${1:-$root/src/leds/leds-uke-rgb.c}
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
cat > "$stage/test.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#define LED_MULTI_COLOR 1
#define EPROBE_DEFER 517
#define IS_ERR(p) ((uintptr_t)(p) >= (uintptr_t)-4095)
#define PTR_ERR(p) ((int)(intptr_t)(p))
struct device_driver {const char *name;};
struct device {const char *name;struct device *parent;struct device_driver *driver;};
struct platform_device {struct device dev;};
struct led_classdev {const char *name;struct device *dev;unsigned flags,max_brightness;};
struct led_classdev_mc;
struct uke_rgb;
static bool board=true;
static unsigned requests;
static struct led_classdev *supplier;
static bool of_machine_is_compatible(const char *name){(void)name;return board;}
static struct led_classdev *devm_of_led_get(struct device *d,int n){(void)d;assert(n==0);++requests;return supplier;}
static int dev_err_probe(struct device *d,int err,const char *msg){(void)d;(void)msg;return err;}
static const char *dev_name(const struct device *d){return d->name;}
static int checked_strcmp(const char *a,const char *b){assert(a && b);return strcmp(a,b);}
#define strcmp checked_strcmp
C
awk '/^static int rgb_probe\(/ {copy=1} copy && /mc = lcdev_to_mccdev/ {exit} copy {print}' "$source" >> "$stage/test.c"
printf '\treturn 0;\n}\n' >> "$stage/test.c"
cat >> "$stage/test.c" <<'C'
int main(void) {
    struct device_driver driver={"qcom-spmi-lpg"};
    struct device parent={.driver=&driver},dev={.name="uke:rgb:status",.parent=&parent};
    struct led_classdev led={.name=NULL,.dev=&dev,.flags=LED_MULTI_COLOR,.max_brightness=511};
    struct platform_device p={0};supplier=&led;
    assert(rgb_probe(&p)==0);
    led.name="legacy-name";assert(rgb_probe(&p)==0);
    led.name="uke:rgb:status";dev.name="wrong-device";assert(rgb_probe(&p)==-ENODEV);dev.name="uke:rgb:status";
    led.flags=0;assert(rgb_probe(&p)==-ENODEV);led.flags=LED_MULTI_COLOR;
    led.max_brightness=512;assert(rgb_probe(&p)==-ENODEV);led.max_brightness=511;
    driver.name="foreign-driver";assert(rgb_probe(&p)==-ENODEV);driver.name="qcom-spmi-lpg";
    parent.driver=NULL;assert(rgb_probe(&p)==-ENODEV);parent.driver=&driver;
    supplier=(void *)(intptr_t)-EPROBE_DEFER;assert(rgb_probe(&p)==-EPROBE_DEFER);
    board=false;unsigned before=requests;assert(rgb_probe(&p)==-ENODEV && requests==before);
}
C
${CC:-cc} -std=c11 -Wall -Wextra -Werror -Wno-unused-variable -Wno-unused-function "$stage/test.c" -o "$stage/test"
"$stage/test"
printf '%s\n' 'Actual RGB supplier admission: registered device name, NULL/legacy input names, foreign identity/driver, brightness, multicolor and deferred supplier checks passed; host only'
