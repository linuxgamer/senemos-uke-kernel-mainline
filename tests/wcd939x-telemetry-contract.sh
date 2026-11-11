#!/usr/bin/env bash
# COPR only: actual Linux declarations/constructor/info/getters, no ALSA device.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
owner=$(cd -- "$(dirname -- "$0")/.." && pwd)
kernel=${1:?Pinned Linux source directory in COPR}
driver=${WCD_TELEMETRY_SOURCE:-$kernel/sound/soc/codecs/wcd939x.c}
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
function_source() {
 awk -v name="$2" '
  $0 ~ "^[a-zA-Z_].*[ *]" name "\\(" && $0 !~ /;/ {emit=1;found=1}
  emit {print}
  emit && /^}/ {exit}
  END {if(!found)exit 1}
 ' "$1"
}
macro_source() {
 awk -v name="$2" '
  $0 ~ "^#define[ \\t]+" name "\\(" {emit=1;found=1}
  emit {print;if($0 !~ /\\$/)exit}
  END {if(!found)exit 1}
 ' "$1"
}
{
 cat "$owner/tests/fixtures/wcd939x-telemetry-host.h"
 for file in include/uapi/sound/asound.h include/sound/control.h; do
  # CONFIG_SND_CTL_DEBUG is unset in this host fixture: select its actual zero definition.
  awk '$2=="SNDRV_CTL_ELEM_ACCESS_SKIP_CHECK" && $3!="0" {next}
   /^#define[ \t]+SNDRV_CTL_ELEM_ACCESS_/ {emit=1}
   emit {print;if($0 !~ /\\$/)emit=0}' "$kernel/$file"
 done
 sed -n '/^struct soc_mixer_control {/,/^};/p' "$kernel/include/sound/soc.h"
 sed -n '/^enum wcd_mbhc_hph_type {/,/^};/p' "$kernel/sound/soc/codecs/wcd-mbhc-v2.h"
 # Old-source controls saved from the actual prepared kernel need their constant.
 if grep -E '^#define WCD939X_ZDET_FLOATING_IMPEDANCE[[:space:]]' "$driver"; then
  :
 else
  grep -E '^#define WCD939X_ZDET_FLOATING_IMPEDANCE[[:space:]]' "$kernel/sound/soc/codecs/wcd939x.c"
 fi
 for name in SOC_DOUBLE_S_VALUE SOC_DOUBLE_VALUE SOC_SINGLE_VALUE SOC_SINGLE_EXT; do
  macro_source "$kernel/include/sound/soc.h" "$name"
 done
 function_source "$kernel/include/sound/soc.h" snd_soc_volsw_is_stereo
 function_source "$kernel/sound/soc/soc-ops.c" soc_info_volsw
 function_source "$kernel/sound/soc/soc-ops.c" snd_soc_info_volsw
 function_source "$kernel/sound/core/control.c" snd_ctl_new1
 function_source "$driver" wcd939x_get_hph_type
 function_source "$driver" wcd939x_hph_impedance_get
 sed -n '/^static const struct snd_kcontrol_new hph_type_detect_controls\[\]/,/^};/p' "$driver"
 sed -n '/^static const struct snd_kcontrol_new impedance_detect_controls\[\]/,/^};/p' "$driver"
 cat "$owner/tests/wcd939x-telemetry-contract.c"
} > "$stage/check.c"
flags=(-std=gnu11 -O1 -g -Wall -Wextra -Werror)
if [[ ${SANITIZE:-1} == 1 ]]; then
 flags+=(-fsanitize=address,undefined -fno-omit-frame-pointer)
fi
"${CC:-gcc}" "${flags[@]}" "$stage/check.c" -o "$stage/check"
ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=1} UBSAN_OPTIONS=${UBSAN_OPTIONS:-halt_on_error=1} "$stage/check" "${WCD_TELEMETRY_MODE:-all}"
