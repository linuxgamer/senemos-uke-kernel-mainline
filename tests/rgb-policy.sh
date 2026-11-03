#!/usr/bin/env bash
# Exercise the actual kernel policy without hardware or a kernel build.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
cat > "$stage/test.c" <<'C'
#include <assert.h>
#include <limits.h>
#include "uke-rgb-policy.h"
int main(void) {
    assert(uke_rgb_battery_mode(15,UKE_RGB_LOW_BATTERY)==UKE_RGB_OFF);
    assert(uke_rgb_battery_mode(14,UKE_RGB_OFF)==UKE_RGB_LOW_BATTERY);
    assert(uke_rgb_battery_mode(5,UKE_RGB_OFF)==UKE_RGB_LOW_BATTERY);
    assert(uke_rgb_battery_mode(4,UKE_RGB_OFF)==UKE_RGB_CRITICAL_BATTERY);
    assert(uke_rgb_battery_mode(0,UKE_RGB_OFF)==UKE_RGB_CRITICAL_BATTERY);
    assert(uke_rgb_battery_mode(-1,UKE_RGB_CRITICAL_BATTERY)==UKE_RGB_CRITICAL_BATTERY);
    assert(uke_rgb_battery_mode(101,UKE_RGB_LOW_BATTERY)==UKE_RGB_LOW_BATTERY);
    assert(uke_rgb_select(1,1,UKE_RGB_CRITICAL_BATTERY,1)==UKE_RGB_FRONT_CAMERA);
    assert(uke_rgb_select(0,1,UKE_RGB_CRITICAL_BATTERY,1)==UKE_RGB_TEST);
    assert(uke_rgb_select(0,0,UKE_RGB_LOW_BATTERY,1)==UKE_RGB_LOW_BATTERY);
    assert(uke_rgb_select(0,0,UKE_RGB_OFF,1)==UKE_RGB_MANUAL);
    for(unsigned t=0;t<20000;++t) {
        struct uke_rgb_frame f=uke_rgb_frame(UKE_RGB_LOW_BATTERY,t,0,0);
        assert(f.rgb==0xff0000 && f.brightness<=8 && f.delay_ms>0);
        if(t%5000>=3000)assert(f.brightness==0);
        struct uke_rgb_frame same=uke_rgb_frame(UKE_RGB_LOW_BATTERY,t+5000,0,0);
        assert(same.brightness==f.brightness && same.delay_ms==f.delay_ms);
        f=uke_rgb_frame(UKE_RGB_CRITICAL_BATTERY,t,0,0);
        assert(f.rgb==0xff0000 && f.brightness==(t%3000<1000?8:0));
        assert(f.delay_ms>0 && f.delay_ms<=2000);
        f=uke_rgb_frame(UKE_RGB_FRONT_CAMERA,t,0,0);
        assert(f.rgb==0x00ff00 && f.brightness<=8 && f.delay_ms>0);
        same=uke_rgb_frame(UKE_RGB_FRONT_CAMERA,t+2000,0,0);
        assert(same.brightness==f.brightness && same.delay_ms==f.delay_ms);
        f=uke_rgb_frame(UKE_RGB_TEST,t,0,0);
        assert(f.rgb<=0xffffff && f.brightness<=8 && f.delay_ms>0);
        if(t>=10000)assert(f.brightness==0);
    }
    const unsigned colors[]={0xff0000,0xffff00,0x00ff00,0x00ffff,0x0000ff,0xff00ff};
    for(unsigned i=0;i<6;++i)assert(uke_rgb_frame(UKE_RGB_TEST,(i*10000+5)/6,0,0).rgb==colors[i]);
    assert(uke_rgb_frame(UKE_RGB_MANUAL,0,0xffff00,UINT_MAX).brightness==8);
    assert(sizeof(struct uke_rgb_color)==16 && sizeof(struct uke_rgb_status)==56);
}
C
${CC:-cc} -std=c11 -Wall -Wextra -Werror -I "$root/src/leds" "$stage/test.c" -o "$stage/test"
"$stage/test"
printf '%s\n' 'Actual kernel RGB policy: thresholds, stale warning retention, 5/3/2 second loops, priority, 10-second rainbow/yellow and PWM bounds: PASS (host only)'
