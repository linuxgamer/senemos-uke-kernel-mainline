#!/usr/bin/env bash
# Compile the real common macro and selected donor table; no MMIO or GPIO I/O.
set -Eeuo pipefail
kernel=${1:?Pass prepared kernel}
source_file=$kernel/drivers/pinctrl/qcom/pinctrl-palawan-lpass-lpi.c
header=$kernel/drivers/pinctrl/qcom/pinctrl-lpass-lpi.h
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
C
awk '/^struct lpi_pingroup {/ {emit=1} emit {print} emit && /^};/ {exit}' "$header" >> "$work/check.c"
awk '/^#define LPI_PINGROUP\(/ {emit=1} emit {print} emit && !/\\$/ {exit}' "$header" >> "$work/check.c"
awk '/^enum lpass_lpi_functions {/ {emit=1} emit {print} emit && /^};/ {exit}' "$source_file" >> "$work/check.c"
awk '/^static const struct lpi_pingroup palawan_groups\[\]/ {emit=1} emit {print} emit && /^};/ {exit}' "$source_file" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
int main(void) {
    assert(ARRAY_SIZE(palawan_groups)==23);
    for(unsigned i=0;i<ARRAY_SIZE(palawan_groups);i++)assert(palawan_groups[i].pin==i);
    assert(palawan_groups[6].funcs[2]==LPI_MUX_i2s1_clk);
    assert(palawan_groups[7].funcs[2]==LPI_MUX_i2s1_ws);
    assert(palawan_groups[8].funcs[2]==LPI_MUX_i2s1_data);
    assert(palawan_groups[9].funcs[2]==LPI_MUX_i2s1_data);
    assert(palawan_groups[12].funcs[0]==LPI_MUX_gpio);
    assert(palawan_groups[0].funcs[1]==LPI_MUX_swr_tx_clk);
    assert(palawan_groups[1].funcs[1]==LPI_MUX_swr_tx_data);
    assert(palawan_groups[3].funcs[1]==LPI_MUX_swr_rx_clk);
    assert(palawan_groups[4].funcs[1]==LPI_MUX_swr_rx_data);
    for(unsigned i=6;i<=12;i++)assert(palawan_groups[i].slew_offset==11&&!palawan_groups[i].pin_offset);
    puts("Actual LPASS table: ordered indices, speaker TDM, GPIO12 reset and selected SoundWire mux slots passed; host only");
}
C
# The upstream common macro uses an int compound literal for unsigned selectors.
${CC:-clang} -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-pointer-sign "$work/check.c" -o "$work/check"
"$work/check"
