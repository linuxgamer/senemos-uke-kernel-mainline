#!/usr/bin/env bash
# COPR only: actual supplier admission with fake driver-core providers.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
owner=$(cd -- "$(dirname -- "$0")/.." && pwd)
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
awk '
 /^static int ssc_link_adsp\(/ {emit=1;found=1}
 emit {print}
 emit && /^}/ {exit}
 END {if(!found)exit 1}
' "$owner/src/sensors/uke-ssc-iio.c" > "$stage/actual.h"
cat > "$stage/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#define EPROBE_DEFER 517
#define DL_FLAG_AUTOREMOVE_CONSUMER 2
struct device { bool locked, bound; };
struct device_link { int unused; };
static struct device consumer, supplier;
static struct device_link link;
static bool allocation_failure;
static unsigned int locked, checked, linked, unlocked;
static void device_lock(struct device *dev)
{
	assert(dev == &supplier && !dev->locked);
	dev->locked = true;
	locked++;
}
static bool device_is_bound(struct device *dev)
{
	assert(dev == &supplier && dev->locked && locked == 1 && !linked);
	checked++;
	return dev->bound;
}
static struct device_link *device_link_add(struct device *c, struct device *s,
					 unsigned int flags)
{
	assert(c == &consumer && s == &supplier && s->locked && s->bound);
	assert(checked == 1 && flags == DL_FLAG_AUTOREMOVE_CONSUMER);
	linked++;
	return allocation_failure ? NULL : &link;
}
static void device_unlock(struct device *dev)
{
	assert(dev == &supplier && dev->locked && checked == 1);
	dev->locked = false;
	unlocked++;
}
#include "actual.h"
static void reset(bool bound, bool fail)
{
	supplier = (struct device){ .bound = bound };
	consumer = (struct device){0};
	allocation_failure = fail;
	locked = checked = linked = unlocked = 0;
}
int main(void)
{
	reset(false, false);
	assert(ssc_link_adsp(&consumer, &supplier) == -EPROBE_DEFER);
	assert(!linked && locked == 1 && unlocked == 1 && !supplier.locked);
	reset(true, true);
	assert(ssc_link_adsp(&consumer, &supplier) == -ENOMEM);
	assert(linked == 1 && unlocked == 1 && !supplier.locked);
	reset(true, false);
	assert(!ssc_link_adsp(&consumer, &supplier));
	assert(linked == 1 && unlocked == 1 && !supplier.locked);
	puts("Actual SSC supplier admission: unbound deferral before linking, locked bound check/link, allocation failure and balanced unlock passed; fake providers only");
}
C
for compiler in gcc clang; do
    "$compiler" -std=gnu11 -O1 -g -Wall -Wextra -Werror \
        -fsanitize=address,undefined -fno-omit-frame-pointer \
        "$stage/check.c" -o "$stage/check"
    ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=1} UBSAN_OPTIONS=${UBSAN_OPTIONS:-halt_on_error=1} "$stage/check"
done
