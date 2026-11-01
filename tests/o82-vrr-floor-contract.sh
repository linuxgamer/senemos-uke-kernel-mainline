#!/usr/bin/env bash
# Execute the actual module-parameter block with the standard parser stubbed.
set -Eeuo pipefail
kernel=${1:?Pass prepared kernel}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
struct kernel_param {void *arg;};
struct kernel_param_ops {
 int (*set)(const char *,const struct kernel_param *);
 int (*get)(char *,const struct kernel_param *);
};
static int param_set_uint(const char *text,const struct kernel_param *parameter) {
 char *end;errno=0;unsigned long value=strtoul(text,&end,0);
 if(errno||end==text||*end||*text=='-'||value>UINT_MAX)return -EINVAL;
 *(unsigned int *)parameter->arg=value;return 0;
}
static int param_get_uint(char *text,const struct kernel_param *parameter) {
 return snprintf(text,32,"%u\n",*(unsigned int *)parameter->arg);
}
static const struct kernel_param_ops standard_ops={param_set_uint,param_get_uint};
#define module_param(name,type,mode) \
 static const struct kernel_param_ops *floor_ops=&standard_ops; \
 static struct kernel_param floor_parameter={&name}
#define module_param_cb(name,ops,arg,mode) \
 static const struct kernel_param_ops *floor_ops=ops; \
 static struct kernel_param floor_parameter={arg}
#define MODULE_PARM_DESC(name,text)
C
awk '/^static unsigned int o82_vrr_test_min_hz;/ {emit=1;found=1}
     emit {print}
     emit&&/^MODULE_PARM_DESC/ {description=1}
     description&&/\);$/ {exit}
     END {if(!found||!description)exit 1}' \
    "$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_encoder.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
int main(void) {
 const unsigned requests[]={0,1,29,30,31,89,90,91,119,143,144,UINT_MAX};
 for(unsigned i=0;i<sizeof(requests)/sizeof(requests[0]);++i) {
  char request[32],readback[32];unsigned actual;
  const unsigned requested=requests[i];
  const unsigned previous=o82_vrr_test_min_hz;
  snprintf(request,sizeof(request),"%u",requested);
  if(requested && (requested<30 || requested>=144)) {
   assert(floor_ops->set(request,&floor_parameter)==-ERANGE);
   assert(o82_vrr_test_min_hz==previous);
   continue;
  }
  assert(!floor_ops->set(request,&floor_parameter));
  assert(o82_vrr_test_min_hz==requested);
  assert(floor_ops->get(readback,&floor_parameter)>0);
  assert(sscanf(readback,"%u",&actual)==1&&actual==requested);
 }
 assert(!floor_ops->set("0x1e",&floor_parameter));
 assert(o82_vrr_test_min_hz==30);
 assert(floor_ops->set("invalid",&floor_parameter)<0&&o82_vrr_test_min_hz==30);
 assert(floor_ops->set("4294967296",&floor_parameter)<0&&o82_vrr_test_min_hz==30);
 assert(floor_ops->set("-1",&floor_parameter)<0&&o82_vrr_test_min_hz==30);
 assert(!floor_ops->set("0",&floor_parameter)&&o82_vrr_test_min_hz==0);
 (void)standard_ops;
 return 0;
}
C
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror "$work/check.c" -o "$work/check"
"$work/check"
printf 'Actual O82 parameter: 30 Hz floor, readback, disabled state and transactional refusal passed\n'
