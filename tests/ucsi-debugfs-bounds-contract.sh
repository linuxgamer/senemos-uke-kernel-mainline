#!/usr/bin/env bash
set -Eeuo pipefail
file=${1:?Pass prepared ucsi/debugfs.c}
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint64_t u64;
struct debug { struct { u64 low,high,ext; } response; int status; unsigned char message_out[256]; };
struct ucsi { struct debug *debugfs; size_t limit; };
#define UCSI_COMMAND(v) ((v)&255)
#define UCSI_COMMAND_DATA_LEN(v) ((void)(v),4)
#define UCSI_MAX_DATA_LENGTH(u) ((u)->limit)
#define min_t(type,a,b) ((type)(a)<(type)(b)?(type)(a):(type)(b))
enum { UCSI_SET_CCOM=1,UCSI_SET_UOR,UCSI_SET_PDR,UCSI_CONNECTOR_RESET,UCSI_SET_SINK_PATH,UCSI_SET_NEW_CAM,UCSI_SET_USB,UCSI_SET_POWER_LEVEL,UCSI_READ_POWER_LEVEL,UCSI_SET_PDOS,UCSI_GET_CAPABILITY,UCSI_GET_CONNECTOR_CAPABILITY,UCSI_GET_ALTERNATE_MODES,UCSI_GET_CAM_SUPPORTED,UCSI_GET_CURRENT_CAM,UCSI_GET_PDOS,UCSI_GET_CABLE_PROPERTY,UCSI_GET_CONNECTOR_STATUS,UCSI_GET_ERROR_STATUS,UCSI_GET_PD_MESSAGE,UCSI_GET_ATTENTION_VDO,UCSI_GET_CAM_CS,UCSI_GET_LPM_PPM_INFO };
static size_t observed;
static int failure;
static int ucsi_send_command(struct ucsi *u,u64 val,void *data,size_t n) {
 (void)val;observed=n;
 if(n>u->limit)return -EINVAL;
 if(failure)return failure;
 if(data)memset(data,0x5a,n);
 return (int)n;
}
static int ucsi_write_message_out_command(struct ucsi *u,u64 v,void *d,size_t n,void *out,size_t len) {
 (void)out;(void)len;return ucsi_send_command(u,v,d,n);
}
C
awk '/^static int ucsi_cmd\(/{emit=1} emit&&/^DEFINE_DEBUGFS_ATTRIBUTE/{exit} emit{print}' "$file" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
int main(void) {
 const unsigned queries[]={UCSI_GET_CAPABILITY,UCSI_GET_CONNECTOR_CAPABILITY,UCSI_GET_ALTERNATE_MODES,UCSI_GET_CAM_SUPPORTED,UCSI_GET_CURRENT_CAM,UCSI_GET_PDOS,UCSI_GET_CABLE_PROPERTY,UCSI_GET_CONNECTOR_STATUS,UCSI_GET_ERROR_STATUS,UCSI_GET_PD_MESSAGE,UCSI_GET_ATTENTION_VDO,UCSI_GET_CAM_CS,UCSI_GET_LPM_PPM_INFO};
 const unsigned limits[]={16,32,256};
 struct debug d;struct ucsi u={.debugfs=&d};
 for(unsigned l=0;l<3;l++)for(unsigned q=0;q<sizeof(queries)/sizeof(queries[0]);q++) {
  u.limit=limits[l];memset(&d,0xff,sizeof(d));
  assert(ucsi_cmd(&u,queries[q])==0 && d.status==0);
  assert(observed==(limits[l]<sizeof(d.response)?limits[l]:sizeof(d.response)));
  assert(d.response.low==UINT64_C(0x5a5a5a5a5a5a5a5a));
  assert(d.response.ext==(limits[l]==16?0:UINT64_C(0x5a5a5a5a5a5a5a5a)));
 }
 assert(ucsi_cmd(&u,UCSI_SET_NEW_CAM)==0 && observed==0);
 failure=-EIO;assert(ucsi_cmd(&u,UCSI_GET_CAPABILITY)==-EIO && d.status==-EIO);
 failure=0;assert(ucsi_cmd(&u,255)==-EOPNOTSUPP && d.status==-EOPNOTSUPP);
 puts("Actual UCSI debugfs: v1/v2 response limits, zero padding, writes, invalid commands and transport errors passed; no firmware change");
}
C
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror "$work/check.c" -o "$work/check"
"$work/check"
