#!/usr/bin/env bash
# Host-only execution of the actual cache-only sysfs getter.
set -Eeuo pipefail
kernel=${1:?Pass prepared Linux source}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
{
cat <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdarg.h>
#include <errno.h>
#include <sys/types.h>
typedef uint32_t u32;
typedef unsigned long long u64;
typedef int64_t s64;
static s64 boot_offset;
#define TK_OFFS_BOOT 1
static s64 ktime_mono_to_any(s64 time, unsigned offset) { assert(!time&&offset==TK_OFFS_BOOT); return boot_offset; }
static s64 ktime_to_ns(s64 time) { return time; }
struct mutex { bool held; };
struct ucsi_connector {
 struct mutex lock;
 void *partner;
 u64 contract_status_seq, contract_status_ns, contract_pdos_seq, contract_pdos_ns;
 s64 contract_boot_offset;
 u32 rdo, src_pdos[7]; int num_pdos;
 u32 status_CONNECTED, status_PWR_DIR, status_PWR_OPMODE, status_RDO;
};
struct power_supply { struct ucsi_connector *con; };
struct device { struct power_supply *psy; };
struct device_attribute { int unused; };
static void *dev_get_drvdata(struct device *d) { return d->psy; }
static void *power_supply_get_drvdata(struct power_supply *p) { return p->con; }
static bool mutex_trylock(struct mutex *m) { if(m->held)return false; m->held=true; return true; }
static void mutex_unlock(struct mutex *m) { assert(m->held); m->held=false; }
#define UCSI_CONSTAT(c, name) ((c)->status_##name)
#define TYPEC_SINK 0
#define UCSI_CONSTAT_PWR_OPMODE_PD 3
#define PDO_MAX_OBJECTS 7
static u32 rdo_index(u32 rdo) { return (rdo >> 28) & 7; }
static int sysfs_emit(char *buf, const char *fmt, ...) {
 va_list ap; va_start(ap, fmt); int n=vsnprintf(buf,4096,fmt,ap); va_end(ap); return n;
}
C
awk '/^static ssize_t uke_pd_contract_show\(/ {emit=1} emit {print} emit && /^}/ {exit}' "$kernel/drivers/usb/typec/ucsi/psy.c"
cat <<'C'
static bool valid(struct device *d) {
 char buf[4096]; unsigned version, v, rdo, pdo, index; int count;
 u64 seq, status, pdos;
 ssize_t n=uke_pd_contract_show(d,NULL,buf); assert(n>0&&n<4096);
 assert(sscanf(buf,"%u %llu %llu %llu %u %u %u %u %d",&version,&seq,&status,&pdos,&v,&rdo,&pdo,&index,&count)==9);
 assert(version==1&&!d->psy->con->lock.held); return v;
}
int main(void) {
 struct ucsi_connector base={.partner=(void*)1,.contract_status_seq=2,.contract_status_ns=100,
  .contract_pdos_seq=2,.contract_pdos_ns=101,.rdo=1U<<28,.src_pdos={123},.num_pdos=1,
  .status_CONNECTED=1,.status_PWR_DIR=TYPEC_SINK,.status_PWR_OPMODE=UCSI_CONSTAT_PWR_OPMODE_PD,.status_RDO=1U<<28};
 struct ucsi_connector con=base; struct power_supply psy={&con}; struct device dev={&psy};
 assert(valid(&dev));
 char busy[4096]; con.lock.held=true; assert(uke_pd_contract_show(&dev,NULL,busy)==-EAGAIN); con.lock.held=false;
 boot_offset=1000; assert(!valid(&dev)); boot_offset=0;
 con=base; con.partner=NULL; assert(!valid(&dev));
 con=base; con.contract_status_ns=0; assert(!valid(&dev));
 con=base; con.contract_pdos_ns=0; assert(!valid(&dev));
 con=base; con.contract_pdos_seq--; assert(!valid(&dev));
 con=base; con.status_CONNECTED=0; assert(!valid(&dev));
 con=base; con.status_PWR_DIR=1; assert(!valid(&dev));
 con=base; con.status_PWR_OPMODE=0; assert(!valid(&dev));
 con=base; con.status_RDO=2U<<28; assert(!valid(&dev));
 con=base; con.num_pdos=0; assert(!valid(&dev));
 con=base; con.rdo=0; con.status_RDO=0; assert(!valid(&dev));
 con=base; con.rdo=7U<<28; con.status_RDO=con.rdo; assert(!valid(&dev));
 puts("Actual UCSI contract getter: coherent cache, detach, suspend, role, epoch and index checks passed; no firmware requests");
}
C
} > "$work/test.c"
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter "$work/test.c" -o "$work/test"
"$work/test"
grep -Fq 'of_machine_is_compatible("xiaomi,uke")' "$kernel/drivers/usb/typec/ucsi/psy.c"
