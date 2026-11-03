#!/usr/bin/env bash
# Run the actual disconnected setter and capability clipping; no device writes.
set -Eeuo pipefail
kernel=${1:?Pass a prepared kernel}
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <algorithm>
#include <cassert>
#include <cerrno>
#include <climits>
#include <cstdio>
#define READ_ONCE(x) (x)
#define WRITE_ONCE(x,v) ((x)=(v))
struct Guard {
    bool* lock;
    explicit Guard(bool* p):lock(p) { assert(!*lock);*lock=true; }
    ~Guard() { assert(*lock);*lock=false; }
};
#define guard(x) const Guard held
struct panel { unsigned lane_limit; };
struct link { unsigned max_dp_lanes; };
struct display { bool active_stream_cnt; };
struct msm_dp_display_private {
    bool plugged_lock=false,plugged=false,stream_pm_active=false,stream_link_attempted=false;
    display msm_dp_display{};
    struct panel* panel;
    struct link* link;
};
CPP
awk '/^static int msm_dp_display_set_lane_limit\(/ {emit=1} emit {print} emit&&/^}/ {exit}' "$kernel/drivers/gpu/drm/msm/dp/dp_display.c" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
unsigned clipped(unsigned sink,unsigned source,unsigned limit,unsigned max_lttpr_lanes) {
    struct {unsigned num_lanes;} caps{sink};auto* link_info=&caps;
    struct {unsigned max_dp_lanes;} provider{source};auto* link=&provider;
    struct {unsigned lane_limit;} policy{limit};auto* msm_dp_panel=&policy;
    using std::min;
CPP
awk '/\/\* Limit data lanes from data-lanes/ {emit=1} emit&&/drm_dbg_dp/ {exit} emit {print}' "$kernel/drivers/gpu/drm/msm/dp/dp_panel.c" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
    return link_info->num_lanes;
}
int main() {
    const unsigned lanes[]{1,2,4};
    for(unsigned source:lanes)for(unsigned wanted:lanes)for(unsigned busy=0;busy<16;busy++) {
        panel p{4};link l{source};msm_dp_display_private dp{};
        dp.panel=&p;dp.link=&l;dp.plugged=busy&1;dp.msm_dp_display.active_stream_cnt=busy&2;
        dp.stream_pm_active=busy&4;dp.stream_link_attempted=busy&8;
        const int expected=wanted>source?-EINVAL:busy?-EBUSY:0;
        assert(msm_dp_display_set_lane_limit(&dp,wanted)==expected);
        assert(!dp.plugged_lock&&p.lane_limit==(expected?4:wanted));
    }
    const unsigned invalid[]{0,3,5,8,UINT_MAX};
    for(unsigned wanted:invalid) {
        panel p{2};link l{4};msm_dp_display_private dp{};dp.panel=&p;dp.link=&l;
        assert(msm_dp_display_set_lane_limit(&dp,wanted)==-EINVAL&&p.lane_limit==2&&!dp.plugged_lock);
    }
    const unsigned repeaters[]{0,1,2,4};
    for(unsigned sink:lanes)for(unsigned source:lanes)for(unsigned limit:lanes)for(unsigned repeater:repeaters)
        assert(clipped(sink,source,limit,repeater)==std::min({sink,source,limit,repeater?repeater:4}));
    puts("Actual DP lane policy: 1/2/4, source limits, all busy states, invalid values and sink/LTTPR clipping passed; host only");
}
CPP
"${CXX:-clang++}" -std=c++20 -O2 -Wall -Wextra -Werror "$work/check.cpp" -o "$work/check"
"$work/check"
