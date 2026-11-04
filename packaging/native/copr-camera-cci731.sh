#!/usr/bin/env bash
# COPR only. Retain the guarded controller and qualify master-1-only CCI reset.
set -Eeuo pipefail
export LC_ALL=C
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?COPR result directory}")
export UKE_CAMERA_BUILD_RELEASE=${UKE_CAMERA_BUILD_RELEASE:-2002}
[[ $UKE_CAMERA_BUILD_RELEASE =~ ^[1-9][0-9]{3,4}$ && $UKE_CAMERA_BUILD_RELEASE -ge 2002 ]]
bash "$owner/packaging/native/copr-camera-controller731.sh" "$output"
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
archive=senemos-native-profile-7.3.1.tar.xz
tar -tJf "$output/$archive" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
tar -xJf "$output/$archive" -C "$stage"
profile=$stage/native-profile
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS)
overlays=(src/camera/cci/0001-i2c-qcom-cci-initialize-all-completions.patch
 src/camera/cci/README731.md tests/camera-cci731-contract.sh
 tests/fixtures/camera-cci-reset-check.c)
for path in "${overlays[@]}"; do
 test ! -e "$profile/$path"
 install -Dm644 "$owner/$path" "$profile/$path"
done
cp "$profile/source-composition.json" "$profile/source-composition-before-cci731.json"
jq '. + {
 source_mode:("retained"+.camera_base_release+"-with-guarded-native-camcc-camss-and-cci-completions"),
 cci_parent_composition:"source-composition-before-cci731.json",
 native_cci_completion_fix:true,camera_cci_dt_activation:false,
 changed_kernel_files:((.changed_kernel_files + ["drivers/i2c/busses/i2c-qcom-cci.c"])|unique),
 device_installation:false,physical_acceptance:false
}' "$profile/source-composition-before-cci731.json" > "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
 -cJf "$output/$archive" -C "$stage" native-profile
spec=$output/senemos-uke-linux-kernel-mainline.spec
[[ $(grep -Fxc '%build' "$spec") == 1 ]]
awk '
 /^%build$/ {
  print "mkdir -p native-generated/cci-before731/drivers/i2c/busses"
  print "cp drivers/i2c/busses/i2c-qcom-cci.c native-generated/cci-before731/drivers/i2c/busses/"
  print "printf '\''45b2dc46ea637f411a39f9352156e91d85a191b4fd3d2bfb44d5b7fc81d57693  drivers/i2c/busses/i2c-qcom-cci.c\\n'\'' | sha256sum -c --strict"
  print "patch -p1 --fuzz=0 -i native-profile/src/camera/cci/0001-i2c-qcom-cci-initialize-all-completions.patch"
  print
  next
 }
 /^uke_build_start=\$SECONDS$/ {
  print
  print "CC=clang bash native-profile/tests/camera-cci731-contract.sh \"$PWD/native-generated/cci-before731\" \"$PWD\""
  print "CC=clang CAMERA_CCI_TEST_FLAGS='\''-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer'\'' bash native-profile/tests/camera-cci731-contract.sh \"$PWD/native-generated/cci-before731\" \"$PWD\""
  next
 }
 /^%check$/ {
  print
  print "test -s %{_uke_out}/drivers/i2c/busses/i2c-qcom-cci.o"
  print "llvm-readelf -h %{_uke_out}/drivers/i2c/busses/i2c-qcom-cci.o | grep -F AArch64"
  print "llvm-nm %{_uke_out}/drivers/i2c/busses/i2c-qcom-cci.o | awk '\''$NF==\"cci_probe\" {found=1} END {exit !found}'\''"
  next
 }
 /^%changelog$/ {
  print
  print "* Wed Nov 04 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-" ENVIRON["UKE_CAMERA_BUILD_RELEASE"]
  print "- Initialize every supported CCI completion before controller reset and IRQ."
  print "- Preserve guarded CAMCC, native CAMSS and the complete retained native cohort."
  print ""; next
 }
 {print}
' "$spec" > "$stage/next.spec"
mv "$stage/next.spec" "$spec"
[[ $(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec") == 7.3.1-$UKE_CAMERA_BUILD_RELEASE ]]
printf 'Prepared kernel %s with actual CCI completion qualification; sensor/EEPROM/capture DT remains inactive\n' "$UKE_CAMERA_BUILD_RELEASE"
