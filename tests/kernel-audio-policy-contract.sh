#!/bin/bash
# COPR-only: parse exact policy data and check parallel-kernel file ownership.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
read -r -a cflags <<< "$(pkg-config --cflags alsa)"
read -r -a libs <<< "$(pkg-config --libs alsa)"
"${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror "${cflags[@]}" \
 "$root/src/audio/desktop/tests/audio-policy.cpp" "${libs[@]}" -o "$work/parser"
for release in 7.3.1-103 7.3.1-104; do
 stage=$work/$release
 driver=uke${release//./_}
 mkdir "$stage"
 bash "$root/src/audio/desktop/install-policy.sh" "$stage" "$release"
 conf=$stage/usr/share/alsa/ucm2/Qualcomm/$driver
 "$work/parser" "$conf/"*.conf
 [[ $(find "$conf" -type f | wc -l) == 9 ]]
 [[ $(find "$stage/usr/share/alsa/ucm2/conf.d/$driver" -type l | wc -l) == 3 ]]
 for name in 'POCO Pad X1' 'Xiaomi Pad 7' POCO-Pad-X1; do
  [[ -r $stage/usr/share/alsa/ucm2/conf.d/$driver/$name.conf ]]
 done
 ! grep -Eq "cset .*name='(ADC[1-4]|TX_DEC[0-3]) Volume'" "$conf/Microphone-HiFi.conf"
 ! grep -R -F '@UKE_AUDIO_DRIVER@' "$conf"
 jq -e --arg components "mic:uke-4ch-v4 kernel:$release" \
  'all(."monitor.alsa.rules"[].matches[];."alsa.components"==$components)' \
  "$stage/usr/share/wireplumber/wireplumber.conf.d/95-uke-microphone-array-$release.conf"
 jq -e '[."monitor.alsa.rules"[].actions."update-props"."node.description"] | index("POCO PAD X1 Speaker") != null and index("Xiaomi Pad 7 Speaker") != null' \
  "$stage/usr/share/wireplumber/wireplumber.conf.d/95-uke-microphone-array-$release.conf"
 grep -Fq "name='ELD',device=0\" \"iface=pcm,name='ELD',device=0" "$conf/DP-ELD.conf"
done
first=$work/7.3.1-103/usr/share
second=$work/7.3.1-104/usr/share
for file in "$root/src/audio/desktop/legacy-ucm2/"*.conf; do
 cmp "$file" "$first/alsa/ucm2/Qualcomm/sm7675/${file##*/}"
 cmp "$file" "$second/alsa/ucm2/Qualcomm/sm7675/${file##*/}"
done
for file in "$root/src/audio/desktop/wireplumber/"*.conf; do
 cmp "$first/wireplumber/wireplumber.conf.d/${file##*/}" "$second/wireplumber/wireplumber.conf.d/${file##*/}"
done
cmp "$first/senemos/uke/audio/microphone-layout.json" "$second/senemos/uke/audio/microphone-layout.json"
printf 'One four-channel UCM source, exact legacy files, scoped rules and disjoint parallel-kernel directories passed; build-host only\n'
