#!/usr/bin/env bash
# Actual initcall with host OF/XBC stubs; no hardware or boot acceptance.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/linux"
cat > "$work/stubs.h" <<'C'
#pragma once
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>
#define __init
#define CONFIG_BOOT_CONFIG 1
#define arch_initcall(fn)
struct xbc_node { bool array; };
struct device_node { int unused; };
struct property { char *name; int length; void *value; };
static bool board = true, soc = true, root_available = true;
static const char *hardware, *product;
static struct xbc_node hn, pn;
static struct device_node root_node;
static struct device_node peripheral_node;
static struct property *saved;
static struct property *peripheral[5];
static unsigned int peripheral_count;
static bool peripherals_present = true;
static int released, update_result;
static bool of_machine_is_compatible(const char *s) { return !strcmp(s,"xiaomi,uke") ? board : soc; }
static const char *xbc_find_value(const char *key, struct xbc_node **node) {
 bool hw = !strcmp(key,"androidboot.hardware.sku");
 const char *value = hw ? hardware : product;
 *node = value && *value ? (hw ? &hn : &pn) : NULL;
 return value;
}
static bool xbc_node_is_array(struct xbc_node *n) { return n->array; }
static struct device_node *of_find_node_by_path(const char *p) {
 if(!strcmp(p,"/"))return root_available ? &root_node : NULL;
 assert(!strcmp(p,"/firmware/uke-accessories") || strstr(p,"/nanosic@4c") ||
        strstr(p,"/novatek@0") || strstr(p,"/ntag@57"));
 return peripherals_present ? &peripheral_node : NULL;
}
static int of_update_property(struct device_node *n, struct property *p) {
 if(!update_result){if(n==&root_node)saved=p;else {assert(peripheral_count<5);peripheral[peripheral_count++]=p;}}
 return update_result;
}
static void of_node_put(struct device_node *n) { assert(n==&root_node||n==&peripheral_node);released++; }
C
for header in bootconfig init of string; do printf '#include "../stubs.h"\n' > "$work/linux/$header.h"; done
printf '#include_next <linux/errno.h>\n' > "$work/linux/errno.h"
cat > "$work/test.c" <<C
#include "$root/src/boot/uke-identity.c"
int main(void) {
 assert(!uke_identity_init() && !saved);
 hardware="ukepgl";product="ukepgl";
 assert(!uke_identity_init() && saved && released==6 && peripheral_count==5);
 assert(!strcmp(saved->name,"model") && saved->length==sizeof("POCO Pad X1") && !strcmp(saved->value,"POCO Pad X1"));
 assert(!strcmp(peripheral[0]->value,"POCO Focus Pen"));
 assert(!strcmp(peripheral[1]->value,"POCO Focus Keyboard"));
 assert(!strcmp(peripheral[2]->value,"POCO Focus Keyboard"));
 assert(!strcmp(peripheral[3]->value,"POCO Pad X1 Touchscreen"));
 assert(!strcmp(peripheral[4]->name,"status") && !strcmp(peripheral[4]->value,"okay"));
 peripheral_count=0;
 saved=NULL;product="other";assert(!uke_identity_init() && !saved);
 product=NULL;hn.array=true;assert(!uke_identity_init() && !saved);
 hn.array=false;hardware="";assert(!uke_identity_init() && !saved);
 hardware="ukepgl ";assert(!uke_identity_init() && !saved);
 hardware="ukepgl";board=false;assert(!uke_identity_init() && !saved);
 board=true;soc=false;assert(!uke_identity_init() && !saved);
 soc=true;root_available=false;assert(uke_identity_init()==-ENODEV && !saved);
 root_available=true;update_result=-ENOMEM;assert(uke_identity_init()==-ENOMEM && !saved && released==7);
 update_result=0;hardware=NULL;product="ukepgl";assert(!uke_identity_init() && saved && released==13);
 peripheral_count=0;peripherals_present=false;
 assert(!uke_identity_init() && saved && released==14 && !peripheral_count);
 return 0;
}
C
${CC:-cc} -std=c11 -Wall -Wextra -Werror -I "$work" "$work/test.c" -o "$work/test"
"$work/test"
printf '%s\n' 'Exact scalar SKU, foreign/conflicting/array refusal, OF lifetime and update errors passed; host only.'
