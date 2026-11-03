#!/usr/bin/env bash
# Actual Uke supply helper; all providers and cleanup actions are memory-only.
set -euo pipefail
kernel=${1:?Pass prepared kernel tree}
source_file=$kernel/sound/soc/codecs/wcd939x.c
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define EPROBE_DEFER 517
struct device_node { unsigned int index; };
struct device { struct device_node *of_node; };
static struct device_node parent, providers[5];
static struct device device = {&parent};
static bool uke;
static int missing, failure_at, failure, bulk_error;
static unsigned int gets, node_puts, enables, bulk_calls, active;
static bool of_machine_is_compatible(const char *name)
{ assert(!strcmp(name, "xiaomi,uke")); return uke; }
static struct device_node *of_parse_phandle(struct device_node *node,
                                           const char *property, int index)
{
 const char *expected[] = {"vdd-rxtx-supply", "vdd-io-supply", "vdd-buck-supply",
                           "vdd-mic-bias-supply", "vdd-px-supply"};
 assert(node == &parent && index == 0 && !enables && gets < 5);
 assert(!strcmp(property, expected[gets]));
 gets++;
 return (int)gets == missing ? NULL : &providers[gets - 1];
}
static void of_node_put(struct device_node *node)
{ assert(node == &providers[node_puts]); node_puts++; }
static int dev_err_probe(struct device *dev, int error, const char *message, ...)
{ assert(dev == &device && message); return error; }
static int devm_regulator_bulk_get_enable(struct device *dev, unsigned int count,
                                         const char *const *names)
{
 assert(dev == &device && count == 5 && names && !uke && !gets && !enables);
 bulk_calls++; return bulk_error;
}
static int devm_regulator_get_enable(struct device *dev, const char *name)
{
 const char *expected[] = {"vdd-rxtx", "vdd-io", "vdd-buck", "vdd-mic-bias", "vdd-px"};
 assert(dev == &device && uke && gets == 5 && node_puts == 5 && !bulk_calls);
 assert(enables < 5 && !strcmp(name, expected[enables]));
 enables++;
 if ((int)enables == failure_at) return failure;
 active++;
 return 0;
}
C
awk '/^static const char \* const wcd939x_supplies\[\]/ {emit=1}
 emit {print} emit && /^};/ {exit}' "$source_file" >> "$work/check.c"
awk '/^static int wcd939x_enable_supplies\(/ {emit=1}
 emit {print} emit && /^}/ {found=1; exit}
 END {if (!found) exit 1}' "$source_file" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static void clear(bool target)
{
 uke = target; gets = node_puts = enables = bulk_calls = active = 0;
 missing = failure_at = failure = bulk_error = 0;
}
int main(void)
{
 const int failures[] = {-EPROBE_DEFER, -ENODEV, -EIO, -ENOMEM};
 for (unsigned int absent = 1; absent <= 5; absent++) {
  clear(true); missing = absent;
  assert(wcd939x_enable_supplies(&device) == -EINVAL);
  assert(gets == absent && node_puts == absent - 1 && !enables && !active && !bulk_calls);
 }
 for (unsigned int stage = 1; stage <= 5; stage++) {
  for (unsigned int error = 0; error < ARRAY_SIZE(failures); error++) {
   clear(true); failure_at = stage; failure = failures[error];
   assert(wcd939x_enable_supplies(&device) == failure);
   assert(enables == stage && active == stage - 1 && gets == 5 && node_puts == 5);
   /* Devres cleanup itself belongs to the kernel API, outside this fixture. */
  }
 }
 clear(true); assert(wcd939x_enable_supplies(&device) == 0);
 assert(enables == 5 && active == 5 && !bulk_calls);
 clear(false); assert(wcd939x_enable_supplies(&device) == 0 && bulk_calls == 1);
 for (unsigned int error = 0; error < ARRAY_SIZE(failures); error++) {
  clear(false); bulk_error = failures[error];
  assert(wcd939x_enable_supplies(&device) == bulk_error && bulk_calls == 1);
  assert(!enables && !gets && !node_puts && !active);
 }
 puts("WCD939x actual Uke supply order: 31 memory-only cases passed; physical power/capture NOT_RUN.");
}
C
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check"
