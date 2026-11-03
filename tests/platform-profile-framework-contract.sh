#!/usr/bin/env bash
# Actual framework init/exit with host kobject/class providers; no sysfs mutation.
set -Eeuo pipefail
kernel=${1:?Pass the prepared kernel source}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/test.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>
#include <errno.h>
#include <stdint.h>
#define __init
#define __exit
#define READ_ONCE(value) (value)
#define WRITE_ONCE(target,value) ((target)=(value))
#define WARN_ON_ONCE(value) ((bool)(value))
#define ERR_PTR(value) ((struct device *)(intptr_t)(value))
struct device { int unused; };
struct platform_profile_ops { void *profile_get, *profile_set, *probe; };
struct kobject { int refs; };
static struct kobject real_acpi, dt_compat, firmware;
static struct kobject *acpi_kobj, *profile_kobj, *firmware_kobj=&firmware;
static bool profile_interface_ready;
static int platform_profile_class, platform_profile_group;
static bool acpi_disabled, populated, fail_alloc;
static int fail_class, fail_group, registered, removed, grouped;
static bool of_have_populated_dt(void) { return populated; }
static struct kobject *kobject_get(struct kobject *obj) { if(obj)obj->refs++; return obj; }
static void kobject_put(struct kobject *obj) { assert(obj && obj->refs>0); obj->refs--; }
static struct kobject *kobject_create_and_add(const char *name, struct kobject *parent) {
 assert(!strcmp(name,"acpi") && parent==firmware_kobj);
 if(fail_alloc)return NULL;
 assert(!dt_compat.refs); dt_compat.refs=1; return &dt_compat;
}
static int class_register(int *cls) { assert(cls==&platform_profile_class); if(fail_class)return fail_class; registered++; return 0; }
static void class_unregister(int *cls) { assert(cls==&platform_profile_class && registered); registered--; }
static int sysfs_create_group(struct kobject *obj,int *group) {
 assert(obj==profile_kobj && group==&platform_profile_group); if(fail_group)return fail_group; grouped++; return 0;
}
static void sysfs_remove_group(struct kobject *obj,int *group) {
 assert(obj==profile_kobj && group==&platform_profile_group && grouped); grouped--; removed++;
}
C
awk '/^struct device \*platform_profile_register\(/ {copy=1} copy&&/struct platform_profile_handler \*pprof/ {print " return (struct device *)1;\n}"; exit} copy' \
    "$kernel/drivers/acpi/platform_profile.c" >> "$work/test.c"
awk '/^static int __init platform_profile_init/ {copy=1} /^module_init\(/ {exit} copy' \
    "$kernel/drivers/acpi/platform_profile.c" >> "$work/test.c"
cat >> "$work/test.c" <<'C'
static void reset(void) {
 assert(!registered && !grouped && !profile_kobj && !profile_interface_ready);
 acpi_disabled=true; populated=false; acpi_kobj=NULL; fail_alloc=false;
 fail_class=fail_group=removed=0; real_acpi.refs=dt_compat.refs=0;
}
int main(void) {
 struct device dev;
 int callback;
 const struct platform_profile_ops ops={&callback,&callback,&callback};
 assert(platform_profile_register(&dev,"fixture",NULL,&ops)==ERR_PTR(-EOPNOTSUPP));
 reset(); assert(platform_profile_init()==-EOPNOTSUPP && !dt_compat.refs);
 populated=true; fail_alloc=true; assert(platform_profile_init()==-ENOMEM && !profile_kobj);
 reset(); populated=true; fail_class=-ENOSPC;
 assert(platform_profile_init()==-ENOSPC && !profile_kobj && !dt_compat.refs && !registered);
 assert(platform_profile_register(&dev,"fixture",NULL,&ops)==ERR_PTR(-EOPNOTSUPP));
 reset(); populated=true; fail_group=-EIO;
 assert(platform_profile_init()==-EIO && !profile_kobj && !dt_compat.refs && !registered);
 reset(); populated=true; assert(!platform_profile_init());
 assert(profile_interface_ready && platform_profile_register(&dev,"fixture",NULL,&ops)==(struct device *)1);
 assert(profile_kobj==&dt_compat && dt_compat.refs==1 && !acpi_kobj && acpi_disabled);
 platform_profile_exit(); assert(!dt_compat.refs && !profile_kobj && removed==1);
 reset(); acpi_disabled=false;
 assert(platform_profile_init()==-ENODEV && !profile_kobj);
 acpi_kobj=&real_acpi; real_acpi.refs=1;
 assert(!platform_profile_init() && profile_kobj==acpi_kobj && real_acpi.refs==2);
 platform_profile_exit(); assert(real_acpi.refs==1 && acpi_kobj==&real_acpi && !profile_kobj);
 reset(); populated=true; acpi_kobj=&real_acpi; real_acpi.refs=1;
 assert(!platform_profile_init() && profile_kobj==acpi_kobj && !dt_compat.refs);
 platform_profile_exit(); assert(real_acpi.refs==1 && !profile_interface_ready);
 return 0;
}
C
${CC:-cc} -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-unused-variable -Wno-unused-parameter "$work/test.c" -o "$work/test"
"$work/test"
printf '%s\n' 'Actual platform-profile init/exit: DT compatibility, original ACPI ownership, allocation/class/group failures and complete reference cleanup passed; host only.'
