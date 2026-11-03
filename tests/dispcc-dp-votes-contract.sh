#!/usr/bin/env bash
# Exercise the actual native DP vote adapters; no clocks or regulators are opened.
set -Eeuo pipefail
source_file=${1:?Pass src/display/uke-dispcc-votes.c}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cerrno>
#include <cstdio>
struct clk_hw { bool prepared; };
static unsigned calls;
static int error;
static bool clk_hw_is_prepared(clk_hw *hw) { return hw->prepared; }
static int vote(unsigned long rate) {
    ++calls;
    if (error) return error;
    return rate && rate <= 675000000UL ? 0 : -EINVAL;
}
static int clk_pre_change_regmap(clk_hw *,unsigned long,unsigned long rate) { return vote(rate); }
static int clk_post_change_regmap(clk_hw *,unsigned long,unsigned long rate) { return vote(rate); }
CPP
awk '/^static int uke_dp_(pre|post)_rate_change\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$source_file" >> "$work/check.cpp"
pre=$(sed -n 's/^[[:space:]]*uke_dp_ops.pre_rate_change = \([a-z_]*\);/\1/p' "$source_file")
post=$(sed -n 's/^[[:space:]]*uke_dp_ops.post_rate_change = \([a-z_]*\);/\1/p' "$source_file")
printf 'static auto pre = %s;\nstatic auto post = %s;\n' "${pre:-clk_pre_change_regmap}" "${post:-clk_post_change_regmap}" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
int main() {
    clk_hw hw{false};
    // A stopped, bypassed RCG must not veto its PHY parent's initial rate.
    assert(pre(&hw,0,1350000000UL)==0);
    assert(post(&hw,0,1350000000UL)==0 && calls==0);
    hw.prepared=true;
    assert(pre(&hw,74250000,148500000)==0 && calls==1);
    assert(post(&hw,148500000,74250000)==0 && calls==2);
    assert(pre(&hw,148500000,1350000000UL)==-EINVAL);
    assert(post(&hw,148500000,0)==-EINVAL);
    error=-EIO;
    assert(pre(&hw,74250000,148500000)==-EIO);
    error=-ENOSPC;
    assert(post(&hw,148500000,74250000)==-ENOSPC);
    // Existing prepare-time validation still refuses invalid output rates.
    error=0;
    assert(vote(0)==-EINVAL && vote(1350000000UL)==-EINVAL);
    assert(vote(74250000)==0);
    puts("Actual DP vote adapters: inactive parent setup, active votes/errors and prepare boundary model passed; host only");
}
CPP
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -Wno-unused-function "$work/check.cpp" -o "$work/check"
"$work/check"
