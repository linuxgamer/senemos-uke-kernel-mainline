#!/usr/bin/env bash
set -Eeuo pipefail
iris=${1:?Pass the prepared Iris directory}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <algorithm>
#include <cassert>
#include <climits>
#include <cstdint>
#include <linux/videodev2.h>
using u64=uint64_t;
#define min_t(t,a,b) std::min<t>(a,b)
#define DIV_ROUND_UP(n,d) (((n)+(d)-1)/(d))
#define NUM_MBS_PER_FRAME(h,w) (DIV_ROUND_UP(h,16)*DIV_ROUND_UP(w,16))
constexpr int DECODER=0,ENCODER=1;
struct platform_data{};
static platform_data sm7675_data,other;
struct iris_core {platform_data *iris_platform_data=&sm7675_data;void *dev=nullptr;};
struct iris_inst {iris_core *core;int domain=DECODER;unsigned operating_rate=60;v4l2_format *fmt_src;};
struct dev_pm_opp{};
static dev_pm_opp good,bad;
static int calls,puts,fail_at;
static bool max_rate;
static dev_pm_opp *dev_pm_opp_find_freq_ceil(void *,unsigned long *rate) {
    ++calls;if(calls==fail_at)return &bad;
    if(max_rate) {*rate=ULONG_MAX;return &good;}
    for(unsigned long candidate:{100ul,200ul,300ul})if(*rate<=candidate){*rate=candidate;return &good;}
    return &bad;
}
static bool IS_ERR(dev_pm_opp *p){return p==&bad;}
static void dev_pm_opp_put(dev_pm_opp *p){assert(p==&good);++puts;}
CPP
awk '/^static u64 iris_serial_decoder_rate\(/ {emit=1} emit {print} emit && /^}/ {exit}' "$iris/iris_power.c" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
int main() {
 iris_core core;v4l2_format fmt{};fmt.fmt.pix_mp.width=3840;fmt.fmt.pix_mp.height=2160;
 iris_inst inst{&core,DECODER,60,&fmt};
 auto reset=[] {calls=puts=fail_at=0;max_rate=false;};
 reset();assert(iris_serial_decoder_rate(&inst,1,150)==300 && calls==2 && puts==2);
 reset();assert(iris_serial_decoder_rate(&inst,1,250)==250 && calls==2 && puts==1);
 for(unsigned depth:{0u,2u,32u}){reset();assert(iris_serial_decoder_rate(&inst,depth,150)==150 && !calls);}
 core.iris_platform_data=&other;reset();assert(iris_serial_decoder_rate(&inst,1,150)==150&&!calls);
 core.iris_platform_data=&sm7675_data;inst.domain=ENCODER;reset();assert(iris_serial_decoder_rate(&inst,1,150)==150&&!calls);
 inst.domain=DECODER;inst.operating_rate=0;reset();assert(iris_serial_decoder_rate(&inst,1,150)==150&&!calls);
 inst.operating_rate=60;fmt.fmt.pix_mp.width=2560;fmt.fmt.pix_mp.height=1440;
 reset();assert(iris_serial_decoder_rate(&inst,1,150)==150&&!calls);
 fmt.fmt.pix_mp.width=3840;fmt.fmt.pix_mp.height=2160;
 for(int failure:{1,2}){reset();fail_at=failure;assert(iris_serial_decoder_rate(&inst,1,150)==150 && puts==failure-1);}
 reset();max_rate=true;assert(iris_serial_decoder_rate(&inst,1,150)==150 && calls==1 && puts==1);
 reset();assert(iris_serial_decoder_rate(&inst,1,ULONG_MAX)==ULONG_MAX && calls==1 && puts==0);
}
CPP
"${CXX:-c++}" -std=c++17 -O2 -Wall -Wextra -Werror "$work/check.cpp" -o "$work/check"
"$work/check"
echo 'Actual serial UHD budget: one existing OPP step, queue/platform/domain/rate/dimension gates, ceiling errors, refcounts and overflow passed (host only)'
