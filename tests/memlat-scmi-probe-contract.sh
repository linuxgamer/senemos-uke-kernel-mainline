#!/usr/bin/env bash
# Execute the diagnostic's actual bounded GET function with SCMI fault injection.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
source=${1:-$root/tests/memlat-scmi-live-probe.c}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint32_t u32;typedef uint32_t __le32;
typedef uint64_t u64;
#define cpu_to_le32(v) (v)
#define le32_to_cpu(v) (v)
#define dev_info(...) ((void)0)
#define lower_32_bits(v) ((u32)(v))
#define upper_32_bits(v) ((u32)((v)>>32))
struct scmi_protocol_handle;
struct buffer { void *buf;size_t len; };
struct scmi_xfer { struct buffer tx,rx; };
struct scmi_xfer_ops {
    int (*xfer_get_init)(const struct scmi_protocol_handle *,u32,size_t,size_t,struct scmi_xfer **);
    int (*do_xfer)(const struct scmi_protocol_handle *,struct scmi_xfer *);
    void (*xfer_put)(const struct scmi_protocol_handle *,struct scmi_xfer *);
};
struct scmi_protocol_handle { const struct scmi_xfer_ops *xops; };
static unsigned gets,xfers,puts_count;
static int alloc_error,xfer_error;
static int word_override;
static u32 word_value,last_command;
static size_t reply_size;
static unsigned char tx[32],rx[16];
static struct scmi_xfer transfer;
static int get(const struct scmi_protocol_handle *ph,u32 command,size_t ts,size_t rs,struct scmi_xfer **out) {
    assert(ph&&((command==0&&ts==0&&rs==8)||
        (command==0x11&&((ts==16&&(rs==8||rs==12))||(ts==28&&rs==8)))));
    gets++;last_command=command;
    if(alloc_error)return alloc_error;
    memset(tx,0xa5,sizeof(tx));memset(rx,0x3c,sizeof(rx));
    if(word_override)memcpy(rx,&word_value,sizeof(word_value));
    transfer=(struct scmi_xfer){.tx={tx,ts},.rx={rx,rs}};*out=&transfer;return 0;
}
static int perform(const struct scmi_protocol_handle *ph,struct scmi_xfer *t) {
    /* Native shmem_fetch_response() clips oversized replies to RX capacity. */
    assert(ph&&t==&transfer);xfers++;
    t->rx.len=reply_size<t->rx.len?reply_size:t->rx.len;return xfer_error;
}
static void put(const struct scmi_protocol_handle *ph,struct scmi_xfer *t) { assert(ph&&t==&transfer);puts_count++; }
static const struct scmi_xfer_ops ops={get,perform,put};
C
awk '/^#define UKE_(MEMLAT|C1DCVS)_(ALGO|GET_)/{print}' "$source" >> "$work/check.c"
awk '/^struct uke_memlat_header/{p=1} p{print} p&&/^};/{exit}' "$source" >> "$work/check.c"
awk '/^static int uke_(cpucp|memlat)_get\(/{p=1} /^struct uke_memlat_probe_ops/{p=0} p{print}' "$source" >> "$work/check.c"
if grep -q '^static int uke_cpucp_version_get' "$source"; then
    printf '#define HAS_CPUCP_OBSERVER 1\n' >> "$work/check.c"
    awk '/^static int uke_memlat_protocol_init\(/{p=1} p{print} p&&/^}/{exit}' "$source" >> "$work/check.c"
fi
cat >> "$work/check.c" <<'C'
static void reset(void) { gets=xfers=puts_count=0;alloc_error=xfer_error=word_override=0;reply_size=8; }
int main(void) {
    _Static_assert(__BYTE_ORDER__==__ORDER_LITTLE_ENDIAN__,"Fixture models the Uke little-endian wire");
    struct scmi_protocol_handle ph={&ops};unsigned char out[8],unchanged[8];u32 request[]={3,0,0};
    memset(unchanged,0x91,sizeof(unchanged));memcpy(out,unchanged,8);reset();
    assert(!uke_memlat_get(&ph,38,NULL,0,out,8)&&gets==1&&xfers==1&&puts_count==1);
    u32 header[4];memcpy(header,tx,sizeof(header));
    assert(header[0]==0&&header[1]==0x4d4c4154&&header[2]==0x4d45&&header[3]==38);
    for(int i=0;i<8;i++)assert(out[i]==0x3c);
    reset();reply_size=4;memcpy(out,unchanged,8);
    assert(!uke_memlat_get(&ph,35,request,12,out,4)&&puts_count==1);
    assert(!memcmp(tx+16,request,12)&&!memcmp(out+4,unchanged+4,4));
    for(size_t actual=0;actual<=16;actual++) {
        reset();reply_size=actual;memcpy(out,unchanged,8);
        int ret=uke_memlat_get(&ph,35,request,12,out,4);
        assert(gets==1&&xfers==1&&puts_count==1);
        if(actual==4)assert(ret==0);
        else assert(ret==-EPROTO&&!memcmp(out,unchanged,8));
    }
    for(int i=0;i<10;i++) {
        reset();memcpy(out,unchanged,8);int ret;
        if(i<3) { reply_size=i;ret=uke_memlat_get(&ph,38,NULL,0,out,8);assert(ret==-EPROTO); }
        else if(i<6) { reply_size=8+i;ret=uke_memlat_get(&ph,38,NULL,0,out,8);assert(ret==-EPROTO); }
        else { xfer_error=-EIO;reply_size=i==6?0:8;ret=uke_memlat_get(&ph,38,NULL,0,out,8);assert(ret==-EIO); }
        assert(gets==1&&xfers==1&&puts_count==1&&!memcmp(out,unchanged,8));
    }
    reset();alloc_error=-ENOMEM;
    assert(uke_memlat_get(&ph,38,NULL,0,out,8)==-ENOMEM&&gets==1&&!xfers&&!puts_count);
    reset();struct scmi_protocol_handle missing={0};
    assert(uke_memlat_get(NULL,38,NULL,0,out,8)==-EINVAL);
    assert(uke_memlat_get(&missing,38,NULL,0,out,8)==-EINVAL);
    assert(uke_memlat_get(&ph,38,NULL,0,NULL,8)==-EINVAL);
    assert(uke_memlat_get(&ph,36,NULL,0,out,8)==-EINVAL);
    assert(uke_memlat_get(&ph,35,NULL,12,out,4)==-EINVAL);
    assert(uke_memlat_get(&ph,35,request,SIZE_MAX,out,4)==-EINVAL);
    assert(uke_memlat_get(&ph,38,NULL,0,out,4)==-EINVAL);
    assert(!gets&&!xfers&&!puts_count);
#ifdef HAS_CPUCP_OBSERVER
    for(unsigned enabled=0;enabled<3;enabled++) {
        reset();reply_size=4;word_override=1;word_value=enabled;
        __le32 result=0xa5a5a5a5;
        int rc=uke_c1dcvs_get_enable(&ph,&result);
        assert(gets==1&&xfers==1&&puts_count==1&&last_command==0x11);
        memcpy(header,tx,sizeof(header));
        assert(header[0]==0&&header[1]==0x44435653&&header[2]==0x4331&&header[3]==1);
        if(enabled<2)assert(!rc&&result==enabled);
        else assert(rc==-EPROTO&&result==0xa5a5a5a5);
    }
    for(size_t actual=0;actual<=12;actual++) {
        reset();reply_size=actual;word_override=1;word_value=0x10000;
        u32 version=0xa5a5a5a5;
        int rc=uke_cpucp_version_get(&ph,&version);
        assert(gets==1&&xfers==1&&puts_count==1&&last_command==0);
        assert(transfer.tx.len==0&&transfer.rx.len<=8);
        if(actual==4)assert(!rc&&version==0x10000);
        else assert(rc==-EPROTO&&version==0xa5a5a5a5);
    }
    for(unsigned error=0;error<2;error++) {
        reset();reply_size=error?4:3;word_override=1;word_value=1;
        xfer_error=error?-EIO:0;__le32 result=0xa5a5a5a5;
        assert(uke_c1dcvs_get_enable(&ph,&result)==(error?-EIO:-EPROTO));
        assert(result==0xa5a5a5a5&&puts_count==1);
    }
    reset();reply_size=4;word_override=1;word_value=0x10000;
    assert(!uke_memlat_protocol_init(&ph));
    reset();reply_size=4;word_override=1;word_value=0x20000;
    assert(uke_memlat_protocol_init(&ph)==-EPROTONOSUPPORT);
    reset();reply_size=4;word_override=1;word_value=0x10000;xfer_error=-EIO;
    assert(uke_memlat_protocol_init(&ph)==-EIO&&puts_count==1);
    reset();alloc_error=-ENOMEM;
    assert(uke_memlat_protocol_init(&ph)==-ENOMEM&&!xfers&&!puts_count);
    reset();__le32 bit=0xa5a5a5a5;u32 version=0xa5a5a5a5;
    assert(uke_c1dcvs_get_enable(&ph,NULL)==-EINVAL);
    assert(uke_cpucp_version_get(&ph,NULL)==-EINVAL);
    assert(uke_cpucp_get(&ph,0,38,NULL,0,out,8)==-EINVAL);
    assert(uke_cpucp_get(&ph,UKE_C1DCVS_ALGO,2,NULL,0,&bit,4)==-EINVAL);
    assert(uke_cpucp_get(&ph,UKE_C1DCVS_ALGO,1,request,12,&bit,4)==-EINVAL);
    assert(uke_cpucp_get(&ph,UKE_MEMLAT_ALGO,1,NULL,0,&bit,4)==-EINVAL);
    assert(!gets&&!xfers&&!puts_count&&version==0xa5a5a5a5);
    puts("PASS: strict wire version, C1DCVS boolean/envelope, namespace refusal and output preservation; host only");
#endif
    puts("PASS: actual MEMLAT GET wire bytes, allowlist, size/null guards, reply/error preservation and xfer release; host only");
}
C
"${CC:-cc}" -std=gnu11 -O1 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check"
