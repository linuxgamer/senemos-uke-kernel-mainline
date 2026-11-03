#!/usr/bin/env bash
# Compile/decode the mixed topology and check the AudioReach ABI; no DSP access.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
bash "$root/tests/speaker-audio-topology-contract.sh"
cat "$root/src/audio/POCO-Pad-X1.conf" "$root/src/audio/POCO-Pad-X1-Microphone-Capture.conf" > "$work/mixed.conf"
alsatplg -c "$work/mixed.conf" -o "$work/card.bin" 2>"$work/compile.log"
alsatplg -d "$work/card.bin" -o "$work/decoded.conf" 2>"$work/decode.log"
sed -n '/^SectionVendorTuples/,$p' "$work/decoded.conf" > "$work/tuples"
test "$(awk '$1=="token201" {print $2}' "$work/tuples" | sort -nu | wc -l)" -eq 13
test "$(awk '$1=="token1" {print $2}' "$work/tuples" | sort -nu | tr '\n' ' ')" = '0 1 2 40 104 120 '
for module in 117444609 117444611 117444612 117444629 117444644; do
 grep -Fq "token200 $module" "$work/tuples"
done
awk "/^SectionPCMCapabilities/ {caps=1} caps && /^\t'MultiMedia3 Capture' \\{/ {emit=1;next} emit && /^\t\\}/ {exit} emit {print}" "$work/decoded.conf" > "$work/caps"
for want in 'channels_min 1' 'channels_max 4' 'rate_min 48000' 'rate_max 48000' "formats 'S16_LE'"; do
 grep -Fq "$want" "$work/caps"
done
awk '/token200 117444644/ {emit=1} emit {print} emit && /^\t*}/ {exit}' "$work/tuples" > "$work/source"
for want in 'token250 4' 'token251 1' 'token253 1' 'token202 0' 'token203 1'; do
 grep -Fq "$want" "$work/source"
done
grep -Fq "stream_name 'TX_CODEC_DMA_TX_3 Capture'" "$work/decoded.conf"
grep -Fq "stream_name 'MultiMedia3 Capture'" "$work/decoded.conf"
for route in 'mic.source, , TX_CODEC_DMA_TX_3 Capture' 'MultiMedia3 Mixer, TX_CODEC_DMA_TX_3, mic.source' 'mic.mfc, , MultiMedia3 Mixer' 'mic.converter, , mic.mfc' 'mic.encoder, , mic.converter' 'mic.rdsh, , mic.encoder'; do
 grep -Fq "$route" "$work/decoded.conf"
done
printf 'Compiled mixed topology: playback checks retained; bounded capture FE2/BE120, unique IDs and CODEC DMA source type1/index4 to RD memory chain passed; no DSP test.\n'
