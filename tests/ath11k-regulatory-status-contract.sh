#!/usr/bin/env bash
# COPR only. Import real enum/conversion/string helpers and diagnostic blocks.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
owner=$(cd -- "$(dirname -- "$0")/.." && pwd)
kernel=${1:?Prepared pinned kernel for unchanged headers}
source_root=${ATH11K_STATUS_SOURCE:-$kernel}
driver=drivers/net/wireless/ath/ath11k
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
function_source() {
 awk -v name="$2" '
  ($0 ~ "^" name "\\(" || $0 ~ "^[a-zA-Z_].*[ *]" name "\\(") && $0 !~ /;/ {emit=1;found=1}
  emit {print}
  emit && /^}/ {exit}
  END {if(!found)exit 1}
 ' "$1"
}
status_block() {
 awk -v name="$2" '
  $0 ~ "^static int " name "\\(" {inside=1}
  inside && /reg_info->reg_dmn_pair =/ {emit=1;next}
  emit {print}
  emit && /reg_info->is_ext_reg_event =/ {found=1;exit}
  END {if(!found)exit 1}
 ' "$1"
}
{
 cat "$owner/tests/fixtures/ath11k-regulatory-status-host.h"
 sed -n '/^enum wmi_reg_cc_setting_code {/,/^};/p' "$kernel/$driver/wmi.h"
 sed -n '/^enum cc_setting_code {/,/^};/p' "$kernel/$driver/wmi.h"
 printf 'static inline enum cc_setting_code\n'
 function_source "$kernel/$driver/wmi.h" ath11k_wmi_cc_setting_code_to_reg
 function_source "$kernel/$driver/wmi.h" ath11k_cc_status_to_str
 cat <<'HOST'
struct cur_regulatory_info {
 enum cc_setting_code status_code;
 char alpha2[2];
 u32 phy_id;
 bool is_ext_reg_event;
};
static void actual_legacy(struct ath11k_base *ab,
                         struct cur_regulatory_info *reg_info, u32 raw)
{
 const struct { u32 status_code; } header = { raw };
 const typeof(header) *chan_list_event_hdr = &header;
HOST
 status_block "$source_root/$driver/wmi.c" ath11k_pull_reg_chan_list_update_ev
 printf '}\n'
 cat <<'HOST'
static void actual_extended(struct ath11k_base *ab,
                           struct cur_regulatory_info *reg_info, u32 raw)
{
 const struct { u32 status_code; } header = { raw };
 const typeof(header) *ev = &header;
HOST
 status_block "$source_root/$driver/wmi.c" ath11k_pull_reg_chan_list_ext_update_ev
 printf '}\n'
 cat <<'HOST'
static int actual_refusal(struct ath11k_base *ab,
                          struct cur_regulatory_info *reg_info)
{
HOST
 # The complete production failure branch is copied verbatim; the remainder
 # of regulatory processing is deliberately outside this diagnostic fixture.
 awk '
  /^\tif \(reg_info->status_code != REG_SET_CC_STATUS_PASS\) {/ {emit=1;found=1}
  emit {print}
  emit && /^\t}/ {exit}
  END {if(!found)exit 1}
 ' "$source_root/$driver/reg.c"
 printf '\treturn 0;\n}\n'
 cat "$owner/tests/ath11k-regulatory-status-contract.c"
} > "$stage/check.c"
flags=(-std=gnu11 -O1 -g -Wall -Wextra -Werror)
if [[ ${SANITIZE:-1} == 1 ]]; then
 flags+=(-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer)
fi
"${CC:-gcc}" "${flags[@]}" "$stage/check.c" -o "$stage/check"
ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 "$stage/check" "${ATH11K_STATUS_MODE:-all}"
