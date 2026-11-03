#!/usr/bin/env bash
# Exercise the actual upstream-derived probe with inert watchdog/SMCCC mocks.
set -Eeuo pipefail
driver=${1:?Gunyah driver source}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
sed -n '/^static int gunyah_wdt_probe(/,/^}/p' "$driver" > "$work/probe.inc"
grep -Fq 'set_bit(WDOG_HW_RUNNING, &wdd->status)' "$work/probe.inc"
cat > "$work/test.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <errno.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#define GFP_KERNEL 0
#define GUNYAH_WDT_STATUS 1
#define WDOG_HW_RUNNING 0
struct device { int unused; };
struct watchdog_device { const void *info,*ops; struct device *parent; unsigned max_timeout,min_timeout,timeout; unsigned long status; };
struct platform_device { struct device dev; void *data; };
static bool boot_enabled,allocation_failed;
static int status_error,start_error,register_error,starts,stops,registrations;
static const int gunyah_wdt_info=1,gunyah_wdt_ops=2;
static struct watchdog_device object;
static int gunyah_wdt_call(int command,int a,int b){assert(command==GUNYAH_WDT_STATUS && !a && !b);return status_error;}
static int dev_err_probe(struct device *device,int error,const char *message){assert(device && message);return error;}
static void *devm_kzalloc(struct device *device,size_t size,int flags){assert(device && size==sizeof(object) && !flags);return allocation_failed?NULL:&object;}
static int gunyah_wdt_start(struct watchdog_device *wdd){assert(wdd==&object && wdd->timeout==32);++starts;return start_error;}
static int gunyah_wdt_stop(struct watchdog_device *wdd){assert(wdd==&object);++stops;return 0;}
static void set_bit(int bit,unsigned long *value){*value|=1UL<<bit;}
static void platform_set_drvdata(struct platform_device *device,void *data){device->data=data;}
static void watchdog_set_restart_priority(struct watchdog_device *wdd,int priority){assert(wdd==&object && !priority);}
static int devm_watchdog_register_device(struct device *device,struct watchdog_device *wdd){assert(device==wdd->parent);++registrations;assert(!boot_enabled || (wdd->status&(1UL<<WDOG_HW_RUNNING)));return register_error;}
#include "probe.inc"
static void reset(void){memset(&object,0,sizeof(object));boot_enabled=allocation_failed=false;status_error=start_error=register_error=starts=stops=registrations=0;}
int main(void){
 struct platform_device device={0};
 reset();assert(!gunyah_wdt_probe(&device));assert(!starts && stops==1 && registrations==1 && !object.status);
 reset();boot_enabled=true;assert(!gunyah_wdt_probe(&device));assert(starts==1 && !stops && registrations==1 && object.timeout==32 && object.min_timeout==1);
 reset();status_error=-EOPNOTSUPP;assert(gunyah_wdt_probe(&device)==-ENODEV);assert(!starts && !stops && !registrations);
 reset();status_error=-EINVAL;assert(gunyah_wdt_probe(&device)==-EINVAL);assert(!starts && !stops && !registrations);
 reset();boot_enabled=allocation_failed=true;assert(gunyah_wdt_probe(&device)==-ENOMEM);assert(!starts && !registrations);
 reset();boot_enabled=true;start_error=-EIO;assert(gunyah_wdt_probe(&device)==-EIO);assert(starts==1 && !registrations && !object.status);
 reset();boot_enabled=true;register_error=-ENOMEM;assert(gunyah_wdt_probe(&device)==-ENOMEM);assert(starts==1 && stops==1 && registrations==1);
 return 0;
}
C
flags=(-std=gnu11 -O2 -Wall -Wextra -Werror)
if [[ ${SANITIZE:-0} == 1 ]]; then flags+=(-fsanitize=undefined -fno-sanitize-recover=all); fi
"${CC:-cc}" "${flags[@]}" "$work/test.c" -o "$work/test"
"$work/test"
printf 'Actual Gunyah probe: default-off, early arming, core handoff and failure cleanup passed; mocked hardware only\n'
