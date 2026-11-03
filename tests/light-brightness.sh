#!/usr/bin/env bash
# Test the actual torch-only setup and brightness callback; no device access.
set -Eeuo pipefail
source=${1:?Pass the patched leds-qcom-flash.c}
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
cat > "$stage/test.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <errno.h>
typedef unsigned u32;
enum led_brightness { LED_OFF=0, LED_FULL=255 };
enum { LED_DEV_CAP_FLASH=1, UA_PER_MA=1000, TORCH_IRES_UA=5000, SW_STROBE, TORCH_MODE };
struct led_classdev { unsigned flags, max_brightness; };
struct led_classdev_flash { struct led_classdev led_cdev; };
struct qcom_flash_led { struct led_classdev_flash flash; unsigned max_torch_current_ma, chan_count; };
static unsigned written_current;
static bool enabled;
static struct led_classdev_flash *lcdev_to_flcdev(struct led_classdev *p) { return (void*)p; }
static struct qcom_flash_led *flcdev_to_qcom_fled(struct led_classdev_flash *p) { return (void*)p; }
static int set_flash_strobe(struct qcom_flash_led *p,unsigned mode,bool value) { (void)p;(void)mode;enabled=value;return 0; }
static int set_flash_module_en(struct qcom_flash_led *p,bool value) { (void)p;(void)value;return 0; }
static int update_allowed_flash_current(struct qcom_flash_led *p,u32 *value,bool on) { assert(*value<=p->max_torch_current_ma);(void)on;return 0; }
static int set_flash_current(struct qcom_flash_led *p,u32 value,unsigned mode) { (void)p;assert(mode==TORCH_MODE);written_current=value;return 0; }
static int set_flash_timeout(struct qcom_flash_led *p,unsigned value) { (void)p;assert(!value);return 0; }
static int setup(struct qcom_flash_led *led) {
    struct led_classdev_flash *flash=&led->flash;
C
awk '/^\tif \(!\(flash->led_cdev.flags & LED_DEV_CAP_FLASH\)\)/ {copy=1} copy {print} copy && /^\t}/ {exit}' "$source" >> "$stage/test.c"
grep -q 'Expose real torch current steps' "$stage/test.c"
printf 'return 0;\n}\n' >> "$stage/test.c"
awk '/^static int qcom_flash_led_brightness_set\(/ {copy=1} copy {print} copy && /^}/ {exit}' "$source" >> "$stage/test.c"
cat >> "$stage/test.c" <<'C'
int main(void) {
    for(unsigned channels=1;channels<=4;++channels) for(unsigned current=1;current<=500*channels;++current) {
        struct qcom_flash_led led={.chan_count=channels,.max_torch_current_ma=current};
        const unsigned step=5*channels;
        int rc=setup(&led);
        if(current<step) {assert(rc==-EINVAL);continue;}
        assert(!rc && led.flash.led_cdev.max_brightness==current/step);
        assert(led.max_torch_current_ma==current/step*step && led.max_torch_current_ma<=current);
        for(unsigned level=0;level<=led.flash.led_cdev.max_brightness;++level) {
            assert(!qcom_flash_led_brightness_set(&led.flash.led_cdev,level));
            assert(written_current==level*step && enabled==(level!=0));
        }
    }
    struct qcom_flash_led uke={.chan_count=2,.max_torch_current_ma=20};
    assert(!setup(&uke) && uke.flash.led_cdev.max_brightness==2);
    struct qcom_flash_led camera={.flash.led_cdev={.flags=LED_DEV_CAP_FLASH,.max_brightness=255},.chan_count=2,.max_torch_current_ma=500};
    assert(!setup(&camera) && camera.flash.led_cdev.max_brightness==255 && camera.max_torch_current_ma==500);
    assert(!qcom_flash_led_brightness_set(&camera.flash.led_cdev,255) && written_current==500);
}
C
${CC:-cc} -std=c11 -Wall -Wextra -Werror "$stage/test.c" -o "$stage/test"
"$stage/test"
printf '%s\n' 'Actual QCOM torch setup/callback: real steps, rounded-down ceiling, zero, Uke 10/20 mA and retained flash ABI: PASS (host only)'
