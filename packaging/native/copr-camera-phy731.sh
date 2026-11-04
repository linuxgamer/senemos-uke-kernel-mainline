#!/usr/bin/env bash
# COPR-only Uke D-PHY helper/source qualification; camera graph stays inactive.
set -Eeuo pipefail
export LC_ALL=C
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?COPR result directory}")
export UKE_CAMERA_BUILD_RELEASE=${UKE_CAMERA_BUILD_RELEASE:-1209}
[[ $UKE_CAMERA_BUILD_RELEASE =~ ^[1-9][0-9]{3,4}$ && $UKE_CAMERA_BUILD_RELEASE -ge 1209 ]]
bash "$owner/packaging/native/copr-camera-native731.sh" "$output"
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
archive=senemos-native-profile-7.3.1.tar.xz
tar -tJf "$output/$archive" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
tar -xJf "$output/$archive" -C "$stage"
profile=$stage/native-profile
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS)
overlays=(src/camera/camss/csiphy-sm7675.h src/camera/camss/README731.md
 tests/camss-sm7675-phy731-contract.sh tests/camss-sm7675-phy-object.sh
 tests/fixtures/camss-sm7675-phy-check.c)
for path in "${overlays[@]}"; do
 test ! -e "$profile/$path"
 install -Dm644 "$owner/$path" "$profile/$path"
done
reference=$profile/referances/camera-phy221
mkdir -p "$reference"
base=https://raw.githubusercontent.com/MiCode/vendor_qcom_opensource_camera-kernel/699fa15a98abd40fbb94f3a6fc00f91723d29d35/drivers/cam_sensor_module/cam_csiphy
curl --fail --location --silent --show-error "$base/include/cam_csiphy_2_2_1_hwreg.h" -o "$reference/cam_csiphy_2_2_1_hwreg.h"
curl --fail --location --silent --show-error "$base/cam_csiphy_core.c" -o "$reference/cam_csiphy_core.c"
curl --fail --location --silent --show-error "$base/cam_csiphy_dev.h" -o "$reference/cam_csiphy_dev.h"
(cd "$reference"; printf '%s\n' \
 '5d5bc215b97bdec610ec4698c49a297c0ccdfab211fb4c3380b8555ef63ca99a  cam_csiphy_2_2_1_hwreg.h' \
 '11f6a85cfb70ca7edbbe3a41c395fbe525c1db822f881171c527de652de78cb9  cam_csiphy_core.c' \
 'efef1af717f54ad458a1db00c989fcaa4fdd775a8572d49ea8924cfad0ccee82  cam_csiphy_dev.h' | sha256sum --check --strict)
cp "$profile/source-composition.json" "$profile/source-composition-before-phy731.json"
jq '. + {
 source_mode:("retained"+(.camera_base_release // "1011")+"-with-unlinked-native-camcc-and-uke-dphy-helper"),
 phy_parent_composition:"source-composition-before-phy731.json",
 native_phy_object:true,native_phy_linked:false,native_phy_installed:false,
 camera_dt_activation:false,physical_acceptance:false
}' "$profile/source-composition-before-phy731.json" > "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
 -cJf "$output/$archive" -C "$stage" native-profile
spec=$output/senemos-uke-linux-kernel-mainline.spec
[[ $(grep -Fxc 'uke_build_start=$SECONDS' "$spec") == 1 ]]
awk '
 /^uke_build_start=\$SECONDS$/ {
  print
  print "CC=clang bash native-profile/tests/camss-sm7675-phy731-contract.sh \"$PWD\""
  print "CC=clang CAMSS_PHY_TEST_FLAGS='\''-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer'\'' bash native-profile/tests/camss-sm7675-phy731-contract.sh \"$PWD\""
  next
 }
 /^bash boot-recipe\/src\/boot\/build-payload.sh / {
  print "bash native-profile/tests/camss-sm7675-phy-object.sh \"$PWD\" %{_uke_out} '\''%{krel}'\''"
 }
 /^%check$/ {
  print
  print "test -z \"$(find %{buildroot} -type f -name '\''*camss-sm7675*'\'' -print -quit)\""
  next
 }
 {print}
' "$spec" > "$stage/next.spec"
mv "$stage/next.spec" "$spec"
[[ $(grep -Fc 'bash native-profile/tests/camss-sm7675-phy-object.sh' "$spec") == 1 ]]
[[ $(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec") == 7.3.1-$UKE_CAMERA_BUILD_RELEASE ]]
printf 'Prepared kernel %s with Uke D-PHY helper/source/object checks; no PHY or graph activation\n' "$UKE_CAMERA_BUILD_RELEASE"
