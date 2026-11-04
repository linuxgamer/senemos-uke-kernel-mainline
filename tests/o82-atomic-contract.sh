#!/usr/bin/env bash
# COPR only: actual caller, physical-stop helper and CTL flush implementation.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
root=$(realpath "${1:?Pass the source owner}")
kernel=$(realpath "${2:?Pass the completely prepared kernel}")
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
{
    grep -E '^#define[[:space:]]+DSPP_IDX[[:space:]]' "$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_hw_ctl.c"
    sed -n '/^static void dpu_hw_ctl_update_pending_flush_dspp_sub_blocks(/,/^}/p' \
        "$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_hw_ctl.c"
    sed -n '/^int dpu_encoder_o82_stopped(/,/^}/p' \
        "$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_encoder.c"
    sed -n '/^struct dpu_o82_color {/,/^int dpu_o82_color_init(/p' \
        "$root/src/display/dpu_o82_color.c" | sed '$d'
    sed -n '/^void dpu_o82_color_fini(/,/^}/p' "$root/src/display/dpu_o82_color.c"
} > "$work/actual.h"
grep -q '^int dpu_o82_color_commit(' "$work/actual.h"
grep -q '^int dpu_encoder_o82_stopped(' "$work/actual.h"
flags=(-std=gnu11 -UNDEBUG -Wall -Wextra -Werror -I"$work")
gcc "${flags[@]}" -O2 "$root/tests/o82-atomic-contract.c" -o "$work/contract"
"$work/contract"
clang "${flags[@]}" -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all \
    "$root/tests/o82-atomic-contract.c" -o "$work/sanitized"
"$work/sanitized"
# Require the real guarded call sites, not only a separately compiled helper.
awk '
 /static void dpu_encoder_virt_atomic_enable/ {f=1;g=0}
 /^void dpu_encoder_prepare_for_kickoff/ {f=2;g=0}
 /^void dpu_encoder_kickoff/ {f=3;g=0}
 f && /if \(dpu_o82_color_blocked\(drm_enc\)\)/ {g=NR;seen[f]=1}
 f==1 && /ops.enable\(/ && !g {bad=1}
 f==2 && /ops.prepare_for_kickoff\(/ && !g {bad=1}
 f==3 && /_dpu_encoder_kickoff_phys\(/ && !g {bad=1}
 /^}/ {f=0}
 END {exit bad || !(seen[1] && seen[2] && seen[3])}
' "$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_encoder.c"
awk '
 /^static void _dpu_crtc_setup_cp_blocks/ {f=1}
 f && /dpu_o82_color_commit\(crtc\)/ {commit=NR}
 f && /ops.setup_pcc/ && !pcc {pcc=NR}
 f && /dpu_o82_color_gc\(crtc, gc_lut\)/ {gc=NR}
 /^}/ {f=0}
 END {exit !(commit && pcc>commit && gc>pcc)}
' "$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_crtc.c"
awk '
 /^bool dpu_crtc_commit_kickoff/ {f=1}
 f && /dpu_o82_color_blocked\(encoder\)/ {guard=NR}
 f && /return false;/ && guard && !refuse {refuse=NR}
 f && /atomic_inc_return\(&dpu_crtc->frame_pending\)/ {pending=NR}
 /^}/ {f=0}
 END {exit !(guard && refuse>guard && pending>refuse)}
' "$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_crtc.c"
