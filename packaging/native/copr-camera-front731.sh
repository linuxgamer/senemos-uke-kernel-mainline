#!/usr/bin/env bash
# COPR only. Exact front GENI/readonly EEPROM admission; capture remains separate.
set -Eeuo pipefail
export LC_ALL=C
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?COPR result directory}")
export UKE_CAMERA_BUILD_RELEASE=${UKE_CAMERA_BUILD_RELEASE:-2006}
[[ $UKE_CAMERA_BUILD_RELEASE =~ ^[1-9][0-9]{3,4}$ && $UKE_CAMERA_BUILD_RELEASE -ge 2006 ]]
bash "$owner/packaging/native/copr-camera-eeprom731.sh" "$output"
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
overlays=(src/camera/eeprom/uke-front-eeprom-dt.h
 src/camera/eeprom/0003-rpmh-front-vio.patch
 src/camera/eeprom/front-eeprom-abl-hook.patch
 src/camera/eeprom/front-eeprom-prepare-hook.patch
 tests/front-eeprom-fdt731-contract.sh tests/fixtures/front-eeprom-fdt-check.c
 tests/front-eeprom-rpmh731-contract.sh src/camera/eeprom/FRONT731.md)
for path in "${overlays[@]}"; do
 test ! -e "$profile/$path"
 install -Dm644 "$owner/$path" "$profile/$path"
done
for tree in "$profile" "$boot"; do
 install -m644 "$owner/src/camera/eeprom/uke-front-eeprom-dt.h" "$tree/src/boot/uke-front-eeprom-dt.h"
 # The boot recipe consumes the already prepared kernel; unlike the native
 # profile it does not carry every source asset listed by earlier recipes.
 if [[ -f $tree/src/boot/uke-abl.c ]]; then
  git -C "$tree" apply --check "$owner/src/camera/eeprom/front-eeprom-abl-hook.patch"
  git -C "$tree" apply "$owner/src/camera/eeprom/front-eeprom-abl-hook.patch"
 fi
 git -C "$tree" apply --check "$owner/src/camera/eeprom/front-eeprom-prepare-hook.patch"
 git -C "$tree" apply "$owner/src/camera/eeprom/front-eeprom-prepare-hook.patch"
 # The hardware inventory uses the canonical node path after native conversion.
 if [[ -f $tree/src/boot/uke-hardware.h ]]; then
  [[ $(grep -Foc '/i2c@880000/qcom,eeprom1' "$tree/src/boot/uke-hardware.h") == 1 ]]
  sed -i 's|/i2c@880000/qcom,eeprom1|/i2c@880000/eeprom@51|' "$tree/src/boot/uke-hardware.h"
 fi
 printf '\n%s\n' 'sha256sum "$here/uke-front-eeprom-dt.h" >> "$output/abl-source-SHA256SUMS"' >> "$tree/src/boot/prepare-abl-source.sh"
 bash -n "$tree/src/boot/prepare-abl-source.sh"
done
cmp "$profile/src/boot/uke-front-eeprom-dt.h" "$profile/src/camera/eeprom/uke-front-eeprom-dt.h"
for path in src/boot/uke-front-eeprom-dt.h src/boot/prepare-abl-source.sh src/boot/uke-abl.c src/boot/uke-hardware.h; do
 test -f "$boot/$path" || continue
 digest=$(sha256sum "$boot/$path"); digest=${digest%% *}
 jq --arg path "$path" --arg digest "$digest" \
  '.source_assets |= (map(select(.path!=$path)) + [{path:$path,sha256:$digest}])' \
  "$boot/lock.json" > "$stage/next-lock.json"
 mv "$stage/next-lock.json" "$boot/lock.json"
done
cp "$boot/lock.json" "$output/boot-payload.json"
cp "$profile/source-composition.json" "$profile/source-composition-before-front731.json"
jq '. + {
 source_mode:("retained"+.camera_base_release+"-with-native-camcc-camss-cci-and-front-eeprom"),
 front_parent_composition:"source-composition-before-front731.json",
 front_geni_dt_activation:true,front_eeprom_dt_activation:true,
 front_eeprom_read_only:true,front_eeprom_size:8192,
 camera_sensor_dt_activation:false,camera_capture_graph_activation:false,
 rear_eeprom_dt_activation:false,calibration_consumed:false,rear_focus:false,
 changed_kernel_files:((.changed_kernel_files + ["arch/arm64/kernel/uke-abl.c",
  "arch/arm64/kernel/uke-hardware.h","arch/arm64/kernel/uke-front-eeprom-dt.h",
  "drivers/regulator/qcom-rpmh-regulator-uke.c"])|unique),
 device_installation:false,physical_acceptance:false
}' "$profile/source-composition-before-front731.json" > "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --quiet -)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
for tree in native-profile boot-recipe; do
 archive=senemos-native-profile-7.3.1.tar.xz
 [[ $tree != boot-recipe ]] || archive=senemos-uke-boot-recipe.tar.xz
 tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner -cJf "$output/$archive" -C "$stage" "$tree"
done
spec=$output/senemos-uke-linux-kernel-mainline.spec
[[ $(grep -Fxc '%build' "$spec") == 1 ]]
awk '
 /^%build$/ {
  print "cp drivers/regulator/qcom-rpmh-regulator-uke.c native-generated/rpmh-before-front731.c"
  print "patch -p1 --fuzz=0 -i native-profile/src/camera/eeprom/0003-rpmh-front-vio.patch"
  print
  next
 }
 /^uke_build_start=\$SECONDS$/ {
  print
  print "CC=clang bash native-profile/tests/front-eeprom-fdt731-contract.sh"
  print "CC=clang FRONT_EEPROM_TEST_FLAGS='\''-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer'\'' bash native-profile/tests/front-eeprom-fdt731-contract.sh"
  print "CXX=clang++ bash native-profile/tests/front-eeprom-rpmh731-contract.sh native-generated/rpmh-before-front731.c drivers/regulator/qcom-rpmh-regulator-uke.c"
  print "CXX=clang++ FRONT_EEPROM_TEST_FLAGS='\''-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer'\'' bash native-profile/tests/front-eeprom-rpmh731-contract.sh native-generated/rpmh-before-front731.c drivers/regulator/qcom-rpmh-regulator-uke.c"
  next
 }
 /^%check$/ {
  print
  print "cmp native-profile/src/camera/eeprom/uke-front-eeprom-dt.h arch/arm64/kernel/uke-front-eeprom-dt.h"
  print "test -s %{_uke_out}/drivers/regulator/qcom-rpmh-regulator-uke.o"
  print "llvm-readelf -h %{_uke_out}/drivers/regulator/qcom-rpmh-regulator-uke.o | grep -F AArch64"
  print "grep -aqF '\''uke-front-calibration'\'' %{_uke_out}/arch/arm64/boot/Image"
  next
 }
 /^%changelog$/ {
  print
  print "* Wed Nov 04 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-" ENVIRON["UKE_CAMERA_BUILD_RELEASE"]
  print "- Admit exact front GENI transport and a private read-only EEPROM provider."
  print "- Retain shared VIO constraints and contain unported sensor/capture nodes."
  print ""; next
 }
 {print}
' "$spec" > "$stage/next.spec"
mv "$stage/next.spec" "$spec"
[[ $(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec") == 7.3.1-$UKE_CAMERA_BUILD_RELEASE ]]
printf 'Prepared %s with front GENI/read-only EEPROM; fitted data, calibrated processing, both sensors, rear AF and full physical acceptance remain open\n' "$UKE_CAMERA_BUILD_RELEASE"
