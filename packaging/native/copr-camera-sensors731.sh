#!/usr/bin/env bash
# COPR-only sensor prerequisite on the retained, independently pinned kernel.
set -Eeuo pipefail
export LC_ALL=C
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?COPR result directory}")
export UKE_CAMCC_BUILD_RELEASE=${UKE_CAMERA_BUILD_RELEASE:-1201}
[[ $UKE_CAMCC_BUILD_RELEASE =~ ^[1-9][0-9]{3,4}$ && $UKE_CAMCC_BUILD_RELEASE -ge 1201 ]]
bash "$owner/packaging/native/copr-camcc-clocks731.sh" "$output"
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
archive=senemos-native-profile-7.3.1.tar.xz
boot_archive=senemos-uke-boot-recipe.tar.xz
for source in "$archive" "$boot_archive"; do
    tar -tJf "$output/$source" > "$stage/entries"
    awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
    tar -xJf "$output/$source" -C "$stage"
done
profile=$stage/native-profile
boot=$stage/boot-recipe
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS)
cmp "$boot/lock.json" "$output/boot-payload.json"
(cd "$boot"; jq -r '.source_assets[] | .sha256 + "  " + .path' lock.json | sha256sum -c -)
overlays=(src/camera/sensors/0001-dt-bindings-media-ov13b10.patch
    src/camera/sensors/0002-media-i2c-ov13b10-of-match.patch
    src/camera/sensors/0003-ov08d10-probe-debug-lanes.patch
    src/camera/sensors/README731.md tests/camera-sensor731-contract.sh
    tests/camera-sensor731-modules.sh tests/fixtures/camera-sensor-hwcfg.c)
for path in "${overlays[@]}"; do
    test ! -e "$profile/$path"
    install -Dm644 "$owner/$path" "$profile/$path"
done
cp "$profile/source-composition.json" "$profile/source-composition-before-sensors731.json"
jq '. + {
 source_mode:("retained"+(.camera_base_release // "1011")+"-with-camera-sensor-modules-and-camcc-prerequisites"),
 sensor_parent_composition:"source-composition-before-sensors731.json",
 camera_sensor_modules:["ov08d10","ov13b10"],camera_dt_activation:false,
 sensor_chip_identification:false,eeprom_access:false,calibration_included:false,
 native_capture_qualified:false,physical_acceptance:false,
 changed_kernel_files:(.changed_kernel_files + ["drivers/media/i2c/ov08d10.c",
   "drivers/media/i2c/ov13b10.c","Documentation/devicetree/bindings/media/i2c/ovti,ov13b10.yaml","MAINTAINERS"])
}' "$profile/source-composition-before-sensors731.json" > "$profile/source-composition.json"
# Change the actual manifest-verified boot configuration, not an unrecorded
# post-verification override. Preserve every other boot source byte.
config=$boot/packaging/native/native.config
cmp "$config" "$profile/native.config"
for sensor in OV08D10 OV13B10; do
    [[ $(grep -Fxc "# CONFIG_VIDEO_$sensor is not set" "$config") == 1 ]]
    sed -i "s/^# CONFIG_VIDEO_$sensor is not set$/CONFIG_VIDEO_$sensor=m/" "$config"
done
config_sha=$(sha256sum "$config"); config_sha=${config_sha%% *}
cp "$config" "$profile/native.config"
jq --arg digest "$config_sha" '.native_config_sha256=$digest' \
 "$profile/source-composition.json" > "$stage/next-composition.json"
mv "$stage/next-composition.json" "$profile/source-composition.json"
[[ $(jq '[.source_assets[] | select(.path=="packaging/native/native.config")]|length' "$boot/lock.json") == 1 ]]
jq --arg digest "$config_sha" '(.source_assets[] |
 select(.path=="packaging/native/native.config").sha256)=$digest' \
    "$boot/lock.json" > "$stage/next-lock.json"
mv "$stage/next-lock.json" "$boot/lock.json"
cp "$boot/lock.json" "$output/boot-payload.json"
(cd "$boot"; jq -r '.source_assets[] | .sha256 + "  " + .path' lock.json | sha256sum -c -)
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
for source in "$archive" "$boot_archive"; do
    case $source in "$archive") directory=native-profile;; *) directory=boot-recipe;; esac
    tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
        -cJf "$output/$source" -C "$stage" "$directory"
done
spec=$output/senemos-uke-linux-kernel-mainline.spec
awk '
 /^bash native-profile\/prepare.sh "\$PWD"$/ {
  print
  print "mkdir -p native-generated/camera-sensors-before731"
  print "cp drivers/media/i2c/ov08d10.c drivers/media/i2c/ov13b10.c native-generated/camera-sensors-before731/"
  print "for sensor_patch in native-profile/src/camera/sensors/000[123]-*.patch; do git apply --check \"$sensor_patch\"; git apply \"$sensor_patch\"; done"
  print "test \"$(find native-profile/src/camera/sensors -name '\''000[123]-*.patch'\'' | wc -l)\" = 3"
  next
 }
 /^uke_build_start=\$SECONDS$/ {
  print
  print "CC=clang bash native-profile/tests/camera-sensor731-contract.sh \"$PWD\" native-generated/camera-sensors-before731"
  print "CC=clang CAMERA_SENSOR_TEST_FLAGS='\''-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer'\'' bash native-profile/tests/camera-sensor731-contract.sh \"$PWD\" native-generated/camera-sensors-before731"
  next
 }
 /^%check$/ {
  print
  print "bash native-profile/tests/camera-sensor731-modules.sh %{_uke_out} %{buildroot} '\''%{krel}'\''"
  next
 }
 {print}
' "$spec" > "$stage/next.spec"
mv "$stage/next.spec" "$spec"
[[ $(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec") == 7.3.1-$UKE_CAMCC_BUILD_RELEASE ]]
printf 'Prepared kernel %s with both native sensor modules; no sensor DT activation or calibration claim\n' "$UKE_CAMCC_BUILD_RELEASE"
