#!/usr/bin/env bash
# Exercise the actual SCMI core admission function, with transfer calls counted.
set -Eeuo pipefail
source=${1:?Pass prepared drivers/firmware/arm_scmi/driver.c}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <errno.h>
struct device { int unused; };
struct scmi_protocol_handle { unsigned version; };
struct scmi_protocol { unsigned id, supported_version; bool no_version_negotiation; };
struct scmi_protocol_instance {
 struct scmi_protocol_handle ph;
 const struct scmi_protocol *proto;
 unsigned version,negotiated_version;
};
static struct scmi_protocol_instance *current;
static unsigned wire_version,negotiations;
static int read_error,negotiation_error;
#define dev_warn(dev,...) ((void)(dev))
#define dev_info(dev,...) ((void)(dev))
static int version_get(struct scmi_protocol_handle *ph,unsigned *out) {
 assert(ph==&current->ph);if(read_error)return read_error;*out=wire_version;return 0;
}
static int scmi_protocol_version_negotiate(struct scmi_protocol_handle *ph) {
 assert(ph==&current->ph);negotiations++;
 if(!negotiation_error)current->negotiated_version=current->proto->supported_version;
 return negotiation_error;
}
C
awk '/^static void scmi_protocol_version_initialize\(/{emit=1}
 emit{print} emit&&/^}/{found=1;exit} END{if(!found)exit 1}' "$source" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
int main(void) {
 struct device dev={0};const unsigned versions[]={0,0x10000,0x20000,~0U};
 for(unsigned strict=0;strict<2;strict++)
  for(unsigned v=0;v<4;v++)
   for(unsigned fail_read=0;fail_read<2;fail_read++)
    for(unsigned fail_neg=0;fail_neg<2;fail_neg++) {
     struct scmi_protocol proto={0x80,0x10000,strict};
     struct scmi_protocol_instance pi={.proto=&proto};current=&pi;
     wire_version=versions[v];read_error=fail_read?-EIO:0;
     negotiation_error=fail_neg?-EOPNOTSUPP:0;negotiations=0;
     scmi_protocol_version_initialize(&dev,&pi);
     unsigned expected_calls=!strict&&!fail_read&&wire_version>proto.supported_version;
     assert(negotiations==expected_calls);
     unsigned expected_version=fail_read?proto.supported_version:
      strict||wire_version<=proto.supported_version?wire_version:proto.supported_version;
     assert(pi.ph.version==expected_version);
     if(expected_calls&&!fail_neg)assert(pi.negotiated_version==proto.supported_version);
     else assert(pi.negotiated_version==0);
    }
 return 0;
}
C
"${CC:-cc}" -std=gnu11 -O1 -Wall -Wextra -Werror -fsanitize=address,undefined \
 -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check"
echo 'PASS: actual SCMI core skips negotiation for strict clients and preserves standard version/fallback behavior; host only'
