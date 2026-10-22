#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Exercise the actual cached reader and protocol-list parser without firmware.
set -Eeuo pipefail
ulimit -c 0
kernel=${1:?Pass the prepared kernel source directory}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
typedef uint8_t u8;
typedef uint32_t u32;
typedef uint32_t __le32;
#define le32_to_cpu(v) (v)
#define cpu_to_le32(v) (v)
#define round_up(v,a) (((v)+(a)-1)&~((a)-1))
#define BASE_DISCOVER_LIST_PROTOCOLS 6
#define dev_err(dev,...) ((void)(dev))
#define dev_warn(dev,...) ((void)(dev))
struct scmi_base_info { int num_protocols; };
struct scmi_info { struct scmi_base_info version; u8 *protocols_imp; int protocols_discovery_status; };
struct device { struct scmi_info *info; };
struct device_attribute {};
static void *dev_get_drvdata(struct device *dev) { return dev->info; }
static int sysfs_emit_at(char *buf, ssize_t offset, const char *fmt, ...) {
 assert(offset>=0 && offset<4096); va_list ap; va_start(ap,fmt);
 int n=vsnprintf(buf+offset,4096-offset,fmt,ap); va_end(ap); return n;
}
struct scmi_protocol_handle;
struct scmi_xfer { struct {void *buf; size_t len;} tx,rx; };
struct ops {
 int (*xfer_get_init)(const struct scmi_protocol_handle *,u8,size_t,size_t,struct scmi_xfer **);
 int (*do_xfer)(const struct scmi_protocol_handle *,struct scmi_xfer *);
 void (*xfer_put)(const struct scmi_protocol_handle *,struct scmi_xfer *);
 void (*reset_rx_to_maxsz)(const struct scmi_protocol_handle *,struct scmi_xfer *);
};
struct scmi_protocol_handle {struct device *dev; const struct ops *xops; void *(*get_priv)(const struct scmi_protocol_handle *);};
static struct scmi_base_info rev;
static unsigned gets,put_count,calls,resets,reply_index;
static int alloc_error,transfer_error;
static u32 counts[3],skip,wire[26];
static size_t lengths[3];
static struct scmi_xfer transfer;
static void *get_priv(const struct scmi_protocol_handle *ph) {(void)ph;return &rev;}
static int get_init(const struct scmi_protocol_handle *ph,u8 cmd,size_t tx,size_t rx,struct scmi_xfer **t) {
 (void)ph; assert(cmd==6 && tx==4 && !rx);gets++;
 if(alloc_error)return alloc_error;
 transfer=(struct scmi_xfer){.tx={&skip,4},.rx={wire,sizeof(wire)}};*t=&transfer;return 0;
}
static int do_xfer(const struct scmi_protocol_handle *ph,struct scmi_xfer *t) {
 (void)ph;assert(t==&transfer && reply_index<3);calls++;
 if(transfer_error)return transfer_error;
 wire[0]=counts[reply_index];memset(wire+1,0xa5,sizeof(wire)-4);
 t->rx.len=lengths[reply_index++];return 0;
}
static void put(const struct scmi_protocol_handle *ph,struct scmi_xfer *t) {(void)ph;assert(t==&transfer);put_count++;}
static void reset(const struct scmi_protocol_handle *ph,struct scmi_xfer *t) {(void)ph;assert(t==&transfer);resets++;}
C
awk '/^static int$/{line=$0;next} /^scmi_base_implementation_list_get\(/ {print line;emit=1} emit {print} emit&&/^}/{exit}' "$kernel/drivers/firmware/arm_scmi/base.c" >> "$work/check.c"
awk '/^static ssize_t implemented_protocols_show\(/ {emit=1} emit {print} emit&&/^}/{exit}' "$kernel/drivers/firmware/arm_scmi/driver.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static void setup(unsigned count) {
 rev.num_protocols=count;gets=put_count=calls=resets=reply_index=0;alloc_error=transfer_error=0;
 memset(counts,0,sizeof(counts));memset(lengths,0,sizeof(lengths));
}
int main(void) {
 const struct ops ops={get_init,do_xfer,put,reset};
 struct scmi_info info={0};struct device dev={&info};
 const struct scmi_protocol_handle ph={&dev,&ops,get_priv};u8 protocols[255]={0};char buf[4096];
 setup(2);counts[0]=2;lengths[0]=8;
 assert(scmi_base_implementation_list_get(&ph,protocols)==0 && gets==1 && put_count==1 && calls==1);
 assert(protocols[0]==0xa5 && protocols[1]==0xa5);
 setup(2);counts[0]=1;lengths[0]=8;counts[1]=1;lengths[1]=8;
 assert(!scmi_base_implementation_list_get(&ph,protocols) && calls==2 && resets==2 && put_count==1);
 setup(0);lengths[0]=4;assert(!scmi_base_implementation_list_get(&ph,protocols) && put_count==1);
 setup(0);lengths[0]=0;assert(scmi_base_implementation_list_get(&ph,protocols)==-EPROTO && put_count==1);
 setup(2);lengths[0]=4;assert(scmi_base_implementation_list_get(&ph,protocols)==-EPROTO && put_count==1);
 setup(2);counts[0]=1;lengths[0]=8;lengths[1]=4;
 assert(scmi_base_implementation_list_get(&ph,protocols)==-EPROTO && calls==2 && put_count==1);
 setup(2);counts[0]=3;lengths[0]=8;assert(scmi_base_implementation_list_get(&ph,protocols)==-EPROTO && put_count==1);
 setup(2);counts[0]=2;lengths[0]=4;assert(scmi_base_implementation_list_get(&ph,protocols)==-EPROTO && put_count==1);
 setup(2);counts[0]=5;lengths[0]=8;rev.num_protocols=5;
 assert(scmi_base_implementation_list_get(&ph,protocols)==-EPROTO && put_count==1);
 setup(2);alloc_error=-ENOMEM;assert(scmi_base_implementation_list_get(&ph,protocols)==-ENOMEM && !put_count && !calls);
 setup(2);transfer_error=-ETIMEDOUT;assert(scmi_base_implementation_list_get(&ph,protocols)==-ETIMEDOUT && put_count==1);
 setup(2);info.protocols_imp=protocols;info.version.num_protocols=2;protocols[0]=0x80;protocols[1]=0x13;
 assert(implemented_protocols_show(&dev,NULL,buf)==10 && !strcmp(buf,"0x80 0x13\n") && !gets && !calls);
 info.protocols_discovery_status=-EPROTO;assert(implemented_protocols_show(&dev,NULL,buf)==-EPROTO && !calls);
 info.protocols_discovery_status=-ENODATA;assert(implemented_protocols_show(&dev,NULL,buf)==-ENODATA && !calls);
 info.protocols_discovery_status=0;info.version.num_protocols=0;
 assert(implemented_protocols_show(&dev,NULL,buf)==1 && !strcmp(buf,"\n"));
 info.version.num_protocols=255;memset(protocols,0xff,sizeof(protocols));
 assert(implemented_protocols_show(&dev,NULL,buf)==1275 && strlen(buf)==1275 && !calls);
 return 0;
}
C
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-sign-compare "$work/check.c" -o "$work/check"
"$work/check"
printf '%s\n' 'SCMI complete/empty/partial/oversized/truncated/error discovery, cleanup and cached no-RPC sysfs checks passed'
