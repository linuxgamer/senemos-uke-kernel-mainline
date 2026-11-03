#!/usr/bin/env bash
# Validate the compiled HDMI and speaker graphs, not merely the source spelling.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
conf=${1:-$root/src/audio/POCO-Pad-X1.conf}
# The HDMI half must stay identical to the separately admitted HDMI profile.
diff <(grep -v -E '^    AR_TKN_(U32|U16)_MODULE_(HW_IF_IDX|HW_IF_TYPE|SYNC_SRC|CTRL_DATA_OUT_ENABLE|SLOT_MASK|NSLOTS_PER_FRAME|SLOT_WIDTH|SYNC_MODE|CTRL_INVERT_SYNC_PULSE|CTRL_SYNC_DATA_DELAY|ACTIVE_LANE_MASK) "' \
      "$root/src/audio/POCO-Pad-X1-HDMI.conf" | sed '/^# Uke digital-only graph/d' | sed '/^$/d') \
     <(sed -n '1,/^# Internal speakers:/p' "$conf" | sed '$d' | grep -v -E '^    AR_TKN_(U32|U16)_MODULE_(HW_IF_IDX|HW_IF_TYPE|SYNC_SRC|CTRL_DATA_OUT_ENABLE|SLOT_MASK|NSLOTS_PER_FRAME|SLOT_WIDTH|SYNC_MODE|CTRL_INVERT_SYNC_PULSE|CTRL_SYNC_DATA_DELAY|ACTIVE_LANE_MASK) "' | sed '/^# Uke digital-only graphs/d' | sed '/^$/d') >/dev/null
alsatplg -c "$conf" -o "$work/card.bin" 2>/dev/null
alsatplg -d "$work/card.bin" -o "$work/decoded.conf" 2>/dev/null
sed -n '/^SectionVendorTuples/,$p' "$work/decoded.conf" > "$work/tuples"
# Modules: HDMI {wrsh, decoder, converter, DP sink} and speaker {wrsh, decoder, converter, TDM sink}.
test "$(awk '$1=="token200" {print $2}' "$work/tuples" | sort -n | tr '\n' ' ')" = \
     '117444608 117444608 117444611 117444611 117444613 117444613 117444622 117444713 '
test "$(awk '$1=="token201" {print $2}' "$work/tuples" | sort -nu | wc -l)" -eq 8
# Four sub-graphs per direction pair: frontends 0/1, backends 104 (DP) and 40 (SECONDARY_TDM_RX_0).
test "$(awk '$1=="token1" {print $2}' "$work/tuples" | sort -nu | tr '\n' ' ')" = '0 1 40 104 '
# TDM sink: LPAIF type 3 (VA), index 0, four 32-bit slots, slot mask 0xf, lane mask 2.
tdm=$(awk '/token200 117444622/ {found=1} found {print} found && /^\t*}/ {exit}' "$work/tuples" | head -40)
for want in 'token250 0' 'token251 3' 'token262 1' 'token263 1' 'token264 15' 'token265 4' 'token266 32' \
            'token267 0' 'token268 0' 'token269 1' 'token272 2' 'token253 1'; do
    grep -Fq "$want" <<< "$tdm" || { echo "TDM sink lacks $want" >&2; exit 1; }
done
grep -Fq "stream_name 'DISPLAY_PORT_RX_0 Playback'" "$work/decoded.conf"
grep -Fq "stream_name 'Secondary TDM0 Playback'" "$work/decoded.conf"
grep -Fq "stream_name 'MultiMedia1 Playback'" "$work/decoded.conf"
grep -Fq "stream_name 'MultiMedia2 Playback'" "$work/decoded.conf"
# Speaker frontend: four channels at 48 kHz, 16-bit (the DSP stalls on width conversion).
awk "/^SectionPCMCapabilities/ {in_caps=1} in_caps && /^\t'MultiMedia2 Playback' \{/ {emit=1; next} emit && /^\t\}/ {exit} emit {print}" "$work/decoded.conf" > "$work/fe2"
grep -Fxq "$(printf '\t\tchannels_min 4')" "$work/fe2"
grep -Fxq "$(printf '\t\tchannels_max 4')" "$work/fe2"
grep -Fxq "$(printf '\t\trate_min 48000')" "$work/fe2"
grep -Fxq "$(printf '\t\trate_max 48000')" "$work/fe2"
grep -Fxq "$(printf "\t\tformats 'S16_LE'")" "$work/fe2"
# Both backends are reachable only through their audio mixers; no capture or other hardware.
grep -Fq "SECONDARY_TDM_RX_0 Audio Mixer" "$work/decoded.conf"
grep -Fq "DISPLAY_PORT_RX_0 Audio Mixer" "$work/decoded.conf"
if grep -E 'Capture|CODEC_DMA|SoundWire|SLIM|MI2S' "$work/decoded.conf"; then exit 1; fi
printf 'Compiled speaker topology: HDMI graph unchanged, TDM sink VA/0/4x32/mask15/lane2, 4-channel frontend passed; host only\n'
