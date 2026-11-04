#!/usr/bin/env bash
# COPR-only permanent GDSC metadata qualification, retaining sensor prerequisites.
set -Eeuo pipefail
export LC_ALL=C
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?COPR result directory}")
export UKE_CAMERA_BUILD_RELEASE=${UKE_CAMERA_BUILD_RELEASE:-1205}
[[ $UKE_CAMERA_BUILD_RELEASE =~ ^[1-9][0-9]{3,4}$ && $UKE_CAMERA_BUILD_RELEASE -ge 1205 ]]
bash "$owner/packaging/native/copr-camera-sensors731.sh" "$output"
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
archive=senemos-native-profile-7.3.1.tar.xz
tar -tJf "$output/$archive" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
tar -xJf "$output/$archive" -C "$stage"
profile=$stage/native-profile
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS)
overlays=(src/camera/provider/0004-clk-qcom-gdsc-permanent-storage.patch
    src/camera/provider/GDSC-STORAGE731.md tests/gdsc-storage731-contract.sh
    tests/fixtures/gdsc-storage-check.h
    src/camera/sensors/0004-ov08d10-exposure-read-errors.patch
    tests/camera-exposure731-contract.sh tests/fixtures/camera-exposure.c)
for path in "${overlays[@]}"; do
    test ! -e "$profile/$path"
    install -Dm644 "$owner/$path" "$profile/$path"
done
cp "$profile/source-composition.json" "$profile/source-composition-before-storage731.json"
jq '. + {
    source_mode:("retained"+(.camera_base_release // "1011")+"-with-sensors-exposure-and-permanent-gdsc-storage-prerequisites"),
    storage_parent_composition:"source-composition-before-storage731.json",
    gdsc_permanent_storage_api:true,gdsc_permanent_storage_callers:0,
    ov08d10_exposure_read_guard:true,
    camera_provider_registered:false,camera_dt_activation:false,physical_acceptance:false
}' "$profile/source-composition-before-storage731.json" > "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
    -cJf "$output/$archive" -C "$stage" native-profile
spec=$output/senemos-uke-linux-kernel-mainline.spec
[[ $(grep -Fc 'bash native-profile/tests/camcc-power-contract.sh' "$spec") == 2 ]]
[[ $(grep -Fxc 'if grep -l GDSC_CONTROLLER_PM drivers/clk/qcom/*-*.c; then exit 1; fi' "$spec") == 1 ]]
awk '
 /^if grep -l GDSC_CONTROLLER_PM drivers\/clk\/qcom\/\*-\*.c; then exit 1; fi$/ {
  print "git apply --check native-profile/src/camera/provider/0004-clk-qcom-gdsc-permanent-storage.patch"
  print "git apply native-profile/src/camera/provider/0004-clk-qcom-gdsc-permanent-storage.patch"
  print "git apply --check native-profile/src/camera/sensors/0004-ov08d10-exposure-read-errors.patch"
  print "git apply native-profile/src/camera/sensors/0004-ov08d10-exposure-read-errors.patch"
 }
 /^uke_build_start=\$SECONDS$/ {
  print
  print "CC=clang bash native-profile/tests/camera-exposure731-contract.sh \"$PWD\" native-generated/camera-sensors-before731"
  print "CC=clang CAMERA_EXPOSURE_TEST_FLAGS='\''-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer'\'' bash native-profile/tests/camera-exposure731-contract.sh \"$PWD\" native-generated/camera-sensors-before731"
  print "CC=clang bash native-profile/tests/gdsc-storage731-contract.sh native-generated/camcc-baseline \"$PWD\""
  print "CC=clang GDSC_STORAGE_TEST_FLAGS='\''-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer'\'' bash native-profile/tests/gdsc-storage731-contract.sh native-generated/camcc-baseline \"$PWD\""
  next
 }
 /bash native-profile\/tests\/camcc-power-contract.sh/ {sub(/^CC=clang /,"CC=clang CAMCC_STORAGE_TEST=1 ")}
 {print}
' "$spec" > "$stage/next.spec"
mv "$stage/next.spec" "$spec"
[[ $(grep -Fxc 'git apply native-profile/src/camera/provider/0004-clk-qcom-gdsc-permanent-storage.patch' "$spec") == 1 ]]
[[ $(grep -Fc 'CC=clang CAMCC_STORAGE_TEST=1 ' "$spec") == 2 ]]
[[ $(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec") == 7.3.1-$UKE_CAMERA_BUILD_RELEASE ]]
printf 'Prepared kernel %s with sensor read guards and permanent GDSC metadata; zero opted-in domains or providers\n' "$UKE_CAMERA_BUILD_RELEASE"
