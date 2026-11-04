#!/usr/bin/env bash
# COPR only: retain touch5000 with the camera4000 driver and test sources.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
manifest=manifests/camera-touch-source-20261104.json
(cd "$owner"; jq -r '.imports[]|.sha256+"  "+.path' "$manifest" | sha256sum -c --strict --quiet -)
output=$(realpath -m "${1:?Remote source result directory}")
revision=${2:?Fresh kernel revision}
[[ $revision =~ ^[1-9][0-9]{3,4}$ && $revision -gt 5000 ]]
for pair in 11252769:5000 11252685:4000; do
 build=${pair%:*} release=${pair#*:}
 curl -fsS --max-time 45 "https://copr.fedorainfracloud.org/api_3/build/$build" | \
  jq -e --arg release "$release" '.state=="succeeded" and
   .source_package.name=="senemos-uke-linux-kernel-mainline" and
   .source_package.version==("7.3.1-"+$release)' >/dev/null
done
bash "$owner/packaging/native/refuse-published-release.sh" \
 senemos-uke-linux-kernel-mainline "7.3.1-$revision"
export UKE_CAMERA_BUILD_RELEASE=$revision UKE_CAMCC_PARENT_RELEASE=5000
bash "$owner/packaging/native/copr-camera-front731.sh" "$output"
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
for archive in senemos-native-profile-7.3.1.tar.xz senemos-uke-boot-recipe.tar.xz; do
 tar -tJf "$output/$archive" > "$stage/entries"
 awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
 tar -xJf "$output/$archive" -C "$stage"
done
profile=$stage/native-profile
boot=$stage/boot-recipe
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --quiet -)
cmp "$boot/lock.json" "$output/boot-payload.json"
cmp "$profile/src/input/nt36532-uke-protocol.c" "$boot/src/input/nt36532-uke-protocol.c"
printf '%s  %s\n' f81f42c2622a6eb671fd7ca11fbb0ce700b6f5a7589a43cb379b5baa7cdfb1ca \
 "$profile/src/input/nt36532-uke-protocol.c" | sha256sum -c --strict
cmp "$profile/native.config" "$boot/packaging/native/native.config"
jq -e '.camera_base_release=="5000" and .camera_base_copr_build==11252769 and
 .camera_base_source_commit=="9d81bed196a7e1ae2018f24b611215b41fd3b75f" and
 .front_geni_dt_activation and .front_eeprom_dt_activation and .front_eeprom_read_only and
 .front_eeprom_size==8192 and (.camera_sensor_dt_activation|not) and
 (.camera_capture_graph_activation|not) and (.rear_eeprom_dt_activation|not) and
 (.calibration_consumed|not) and (.rear_focus|not) and
 .touch_gesture_setting_path=="OEM-mandatory-ACK-without-extra-getters" and
 .touch_coordinate_readback_preserved and .touch_mandatory_errors_preserved and
 .touch_panel_order_unchanged and .ath11k_regulatory_policy_unchanged and
 (.physical_acceptance|not)' "$profile/source-composition.json" >/dev/null
cp "$profile/source-composition.json" "$profile/source-composition-before-camera-touch.json"
install -Dm644 "$owner/$manifest" "$profile/$manifest"
jq '. + {
 source_mode:"retained5000-with-qualified-camera4000-front-provider",
 camera_recipe_reference_build:11252685,
 camera_recipe_reference_source:"8dce4ab204a2608bc112cb7ceaa411e3b647afcd",
 camera_reference_effective_config_sha256:"7f1e3f7a5be62396b2b36534780aeb561dfbf7e0a10698677b860cbc91efbd38",
 touch_reference_build:11252769,
 touch_reference_source:"9d81bed196a7e1ae2018f24b611215b41fd3b75f",
 camera_touch_source_manifest:"manifests/camera-touch-source-20261104.json",
 camera_touch_parent_composition:"source-composition-before-camera-touch.json",
 device_installation:false,physical_acceptance:false
}' "$profile/source-composition-before-camera-touch.json" > "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
 -cJf "$output/senemos-native-profile-7.3.1.tar.xz" -C "$stage" native-profile
spec=$output/senemos-uke-linux-kernel-mainline.spec
awk '
 /^%check$/ {
  print
  print "printf '\''7f1e3f7a5be62396b2b36534780aeb561dfbf7e0a10698677b860cbc91efbd38  %{_uke_out}/.config\\n'\'' | sha256sum -c --strict"
  next
 }
 {print}
' "$spec" > "$stage/next.spec"
install -m644 "$stage/next.spec" "$spec"
for required in \
 'bash native-profile/tests/touch-gesture-ack-regression.sh' \
 'bash native-profile/tests/touch-gesture-ack-package-contract.sh "$PWD" %{_uke_out}' \
 'CC=clang bash native-profile/tests/front-eeprom-fdt731-contract.sh'; do
 [[ $(grep -Fxc "$required" "$spec") == 1 ]]
done
[[ $(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec") == 7.3.1-$revision ]]
printf 'Combined native touch/camera source prepared; full captures, fitted private calibration and rear autofocus remain required\n'
