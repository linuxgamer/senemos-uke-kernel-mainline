#!/bin/bash
# COPR install stage only: coexist with parallel kernels and the legacy policy.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
root=$(cd -- "$(dirname -- "$0")" && pwd)
destination=${1:?RPM buildroot}
release=${2:?kernel release}
[[ $destination == /* && $release =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]]
driver=uke${release//./_}
[[ ${#driver} -lt 16 ]]
ucm=$destination/usr/share/alsa/ucm2
for config in "$root/legacy-ucm2/"*.conf; do
 install -Dm644 "$config" "$ucm/Qualcomm/sm7675/${config##*/}"
done
mkdir -p "$ucm/conf.d/sm7675"
for name in POCO-Pad-X1 POCO-Pad-X1-HDMI; do
 ln -s "../../Qualcomm/sm7675/$name.conf" "$ucm/conf.d/sm7675/$name.conf"
done
mkdir -p "$ucm/Qualcomm/$driver" "$ucm/conf.d/$driver"
for config in "$root/array-ucm2/"*.conf; do
 sed "s/@UKE_AUDIO_DRIVER@/$driver/g" "$config" > "$ucm/Qualcomm/$driver/${config##*/}"
 chmod 644 "$ucm/Qualcomm/$driver/${config##*/}"
done
for name in 'POCO Pad X1' 'Xiaomi Pad 7' POCO-Pad-X1; do
 ln -s "../../Qualcomm/$driver/POCO-Pad-X1.conf" "$ucm/conf.d/$driver/$name.conf"
done
wp=$destination/usr/share/wireplumber/wireplumber.conf.d
for config in "$root/wireplumber/"*.conf; do
 install -Dm644 "$config" "$wp/${config##*/}"
done
jq --arg components "mic:uke-4ch-v4 kernel:$release" --slurpfile names "$root/model-names.conf" \
 '."monitor.alsa.rules" += $names[0]."monitor.alsa.rules" | ."monitor.alsa.rules"[].matches[] += {"alsa.components":$components}' \
 "$root/wireplumber/80-uke-microphone-array.conf" > "$wp/95-uke-microphone-array-$release.conf"
chmod 644 "$wp/95-uke-microphone-array-$release.conf"
install -Dm644 "$root/microphone-layout.json" "$destination/usr/share/senemos/uke/audio/microphone-layout.json"
install -Dm644 "$root/microphone-layout.json" "$destination/usr/share/senemos/uke/$release/microphone-layout.json"
install -Dm644 "$root/LICENSE" "$destination/usr/share/licenses/uke-kernel-audio-$release/LICENSE"
