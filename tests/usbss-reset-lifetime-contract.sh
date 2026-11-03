#!/usr/bin/env bash
# Actual probe-unwind tail and remove callback; no I2C, pins or device access.
set -Eeuo pipefail
source_file=${1:?Pass Uke USBSS source}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/test.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#define EPROBE_DEFER 517
#define BIT(n) (1U<<(n))
#define GENMASK(h,l) ((~0U>>(31-(h)))&(~0U<<(l)))
C
grep -E '^#define (SWITCH_ENABLE|AUX_EN|USB_EN|EQUALIZER|EQ_EN) ' "$source_file" >> "$work/test.c"
if grep -q '^depopulate_children:' "$source_file"; then
    echo '#define HAS_PARTIAL_CHILD_PATH 1' >> "$work/test.c"
else
    echo '#define HAS_PARTIAL_CHILD_PATH 0' >> "$work/test.c"
fi
cat >> "$work/test.c" <<'C'
struct device { int unused; };
struct uke_usbss { void *regmap,*supply,*reset,*sw,*mux;int lock;bool removing,applied; };
struct i2c_client { struct device dev;struct uke_usbss *data; };
static struct uke_usbss usbss;
static struct i2c_client client;
static bool child,managed,powered,sw_registered,mux_registered;
static int raw_depop,managed_depop,reset_asserted;
static void mutex_lock(int *lock) { assert(!*lock);(*lock)++; }
static void mutex_unlock(int *lock) { assert(*lock==1);(*lock)--; }
static struct uke_usbss *i2c_get_clientdata(struct i2c_client *c) { assert(c==&client);return c->data; }
static void typec_switch_unregister(void *p) { assert(p==usbss.sw&&sw_registered&&!usbss.lock);sw_registered=false; }
static void typec_mux_unregister(void *p) { assert(p==usbss.mux&&mux_registered&&!usbss.lock&&!child);mux_registered=false; }
static void of_platform_depopulate(struct device *d) {
    assert(d==&client.dev&&powered&&!managed&&usbss.removing&&!usbss.applied&&!usbss.lock);
    child=false;raw_depop++;
}
static void devm_of_platform_depopulate(struct device *d) {
    assert(d==&client.dev&&powered&&managed&&usbss.removing&&!usbss.applied&&!usbss.lock);
    child=false;managed=false;managed_depop++;
}
static int regmap_clear_bits(void *p,unsigned reg,unsigned mask) { assert(p==usbss.regmap&&powered&&!child);(void)reg;(void)mask;return 0; }
static void gpiod_set_value_cansleep(void *p,int value) { assert(p==usbss.reset&&value==1&&powered&&!child);reset_asserted++; }
static int regulator_disable(void *p) { assert(p==usbss.supply&&powered&&!child&&!sw_registered&&!mux_registered);powered=false;return 0; }
static int dev_err_probe(struct device *d,int error,const char *message) { assert(d==&client.dev&&error<0&&message);return error; }
static int unwind(struct uke_usbss *u,struct device *dev,int ret,bool early) {
    if(early)goto power_off;
#if HAS_PARTIAL_CHILD_PATH
    if(child)goto depopulate_children;
#endif
    goto unregister_switch;
C
awk '/^(depopulate_children|unregister_switch):/ {emit=1} emit {print} emit && /^}/ {exit}' "$source_file" >> "$work/test.c"
awk '/^static void uke_usbss_remove\(/ {emit=1} emit {print} emit && /^}/ {exit}' "$source_file" >> "$work/test.c"
cat >> "$work/test.c" <<'C'
static void start(void) {
    usbss=(struct uke_usbss){.regmap=(void*)1,.supply=(void*)2,.reset=(void*)3,.sw=(void*)4,.mux=(void*)5,.applied=true};
    client.data=&usbss;child=managed=false;powered=sw_registered=mux_registered=true;
    raw_depop=managed_depop=reset_asserted=0;
}
int main(void) {
    const int errors[]={-EIO,-ENOMEM,-EPROBE_DEFER};
    for(unsigned i=0;i<3;i++) {
        start();child=true;mux_registered=HAS_PARTIAL_CHILD_PATH;
        assert(unwind(&usbss,&client.dev,errors[i],false)==errors[i]);
        assert(!child&&!powered&&!sw_registered&&!mux_registered&&raw_depop==1&&reset_asserted==1);
        assert(usbss.removing&&!usbss.applied);
    }
    start();mux_registered=false;assert(unwind(&usbss,&client.dev,-ENOMEM,false)==-ENOMEM);
    assert(!raw_depop&&!powered);
    start();sw_registered=mux_registered=false;assert(unwind(&usbss,&client.dev,-ENODEV,true)==-ENODEV);
    assert(!raw_depop&&!managed_depop&&!powered);
    for(int present=0;present<=1;present++) {
        start();child=present;managed=true;uke_usbss_remove(&client);
        assert(!powered&&!child&&!sw_registered&&!mux_registered&&managed_depop==1&&!raw_depop);
        assert(usbss.removing&&!usbss.applied&&reset_asserted==1);
    }
    puts("Actual USBSS unwind/remove: partial-child cleanup, first error, quiesce and child-before-power ordering passed; host only");
}
C
${CC:-clang} -std=gnu11 -O1 -g -Wall -Wextra -Werror -Wno-unused-function -fsanitize=address,undefined "$work/test.c" -o "$work/test"
ASAN_OPTIONS=detect_leaks=1 "$work/test"
