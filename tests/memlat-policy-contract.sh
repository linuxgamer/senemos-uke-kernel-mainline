#!/usr/bin/env bash
# COPR host only: execute the actual policy on valid, rejected and boundary samples.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
typedef uint32_t u32;
typedef uint64_t u64;
static u64 div64_u64(u64 a, u64 b) { assert(b); return a/b; }
C
printf '#include "%s/src/power/uke-memlat-policy.h"\n' "$root" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
int main(void)
{
    struct uke_memlat_count old={10,100,100},now={30,200,200};u64 delta=0;
    assert(uke_memlat_delta(&now,&old,&delta)&&delta==20);
    now.running=199;assert(!uke_memlat_delta(&now,&old,&delta));
    now.running=100;assert(!uke_memlat_delta(&now,&old,&delta));
    now=old;assert(!uke_memlat_delta(&now,&old,&delta));
    now=(struct uke_memlat_count){9,200,200};assert(!uke_memlat_delta(&now,&old,&delta));
    now=(struct uke_memlat_count){30,99,200};assert(!uke_memlat_delta(&now,&old,&delta));
    now=(struct uke_memlat_count){30,200,99};assert(!uke_memlat_delta(&now,&old,&delta));
    struct uke_memlat_row map[]={ {902400,300000},{1478400,466500},{1843200,600000} };
    assert(uke_memlat_map_valid(map,3,1066000));
    assert(!uke_memlat_map_valid(map,0,1066000));
    assert(!uke_memlat_map_valid(map,13,1066000));
    assert(!uke_memlat_map_valid(map,3,599999));
    struct uke_memlat_row bad[]={ {1000,1000},{1000,2000} };
    assert(!uke_memlat_map_valid(bad,2,3000));
    bad[1].cpu_khz=2000;bad[1].memory_khz=999;
    assert(!uke_memlat_map_valid(bad,2,3000));
    bad[1].memory_khz=0;assert(!uke_memlat_map_valid(bad,2,3000));
    bad[1].memory_khz=2000;bad[1].cpu_khz=5000001;
    assert(!uke_memlat_map_valid(bad,2,3000));
    /* 8 ms window: exact OEM integer-MHz ceiling behavior at every boundary. */
    const u64 ns=8000000;
    const unsigned mhz[]={1,902,903,1478,1479,1843,1844,5000};
    const unsigned expected[]={300000,300000,466500,466500,600000,600000,600000,600000};
    for(unsigned i=0;i<sizeof(mhz)/sizeof(*mhz);i++) {
        assert(uke_memlat_vote(map,3,false,400000,(u64)mhz[i]*8000,1000,ns)==expected[i]);
        assert(uke_memlat_vote(map,3,true,UINT64_MAX,(u64)mhz[i]*8000,0,ns)==expected[i]);
    }
    assert(!uke_memlat_vote(map,3,false,401000,8000000,1000,ns));
    assert(!uke_memlat_vote(map,3,false,0,8000000,0,ns));
    assert(!uke_memlat_vote(map,3,true,0,0,0,ns));
    assert(!uke_memlat_vote(map,3,true,0,8000000,0,99999));
    assert(!uke_memlat_vote(map,3,true,0,8000000,0,1000000001));
    assert(!uke_memlat_vote(map,3,true,0,UINT64_MAX,0,ns));
    assert(!uke_memlat_vote(map,3,true,0,40000001,0,ns));
    assert(!uke_memlat_vote(map,3,true,0,1,0,ns));
    puts("Uke MEMLAT: actual counter admission, scheduling gaps, map bounds, IPM and ceiling policy pass; host only");
}
C
"${CC:-clang}" -std=c11 -Wall -Wextra -Werror -fsanitize=undefined,address -fno-sanitize-recover=all "$work/check.c" -o "$work/check"
"$work/check"
