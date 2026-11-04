#!/usr/bin/env bash
# COPR only. Read-only EEPROM voltage prerequisite; no EEPROM DT activation.
set -Eeuo pipefail
export LC_ALL=C
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?COPR result directory}")
export UKE_CAMERA_BUILD_RELEASE=${UKE_CAMERA_BUILD_RELEASE:-2004}
[[ $UKE_CAMERA_BUILD_RELEASE =~ ^[1-9][0-9]{3,4}$ && $UKE_CAMERA_BUILD_RELEASE -ge 2004 ]]
bash "$owner/packaging/native/copr-camera-cci731.sh" "$output"
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
archive=senemos-native-profile-7.3.1.tar.xz
tar -tJf "$output/$archive" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
tar -xJf "$output/$archive" -C "$stage"
profile=$stage/native-profile
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS)
overlays=(src/camera/eeprom/0001-at24-readonly-vcc.patch
 src/camera/eeprom/0002-at24-readonly-vcc-binding.patch
 src/camera/eeprom/at24-vcc-readonly.h src/camera/eeprom/README731.md
 tests/at24-vcc731-contract.sh tests/fixtures/at24-vcc-readonly-check.c
 tests/camera-nvmem-privacy731-contract.sh tests/fixtures/camera-nvmem-privacy-check.c)
for path in "${overlays[@]}"; do
 test ! -e "$profile/$path"
 install -Dm644 "$owner/$path" "$profile/$path"
done
cp "$profile/source-composition.json" "$profile/source-composition-before-eeprom731.json"
jq '. + {
 source_mode:("retained"+.camera_base_release+"-with-native-camcc-camss-cci-and-readonly-eeprom-vcc"),
 eeprom_parent_composition:"source-composition-before-eeprom731.json",
 native_at24_readonly_vcc:true,front_eeprom_dt_activation:false,rear_eeprom_dt_activation:false,
 changed_kernel_files:((.changed_kernel_files + ["drivers/nvmem/at24.c",
  "drivers/nvmem/at24-vcc-readonly.h","Documentation/devicetree/bindings/eeprom/at24.yaml"])|unique),
 device_installation:false,physical_acceptance:false
}' "$profile/source-composition-before-eeprom731.json" > "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
 -cJf "$output/$archive" -C "$stage" native-profile
spec=$output/senemos-uke-linux-kernel-mainline.spec
[[ $(grep -Fxc '%build' "$spec") == 1 ]]
awk '
 /^BuildRequires:/ && !schema_dependency++ {
  print "BuildRequires: dt-schema = 2026.09-1.fc46"
 }
 /^%build$/ {
  print "mkdir -p native-generated/at24-before731/drivers/nvmem"
  print "cp drivers/nvmem/at24.c native-generated/at24-before731/drivers/nvmem/"
  print "printf '\''f37ed370a86b2b850625ecd7e5e4d810b5feeb65c10f719a9e505aa8db2795a0  drivers/nvmem/at24.c\\n'\'' | sha256sum -c --strict"
  print "printf '\''98452b4e32c41de9f74608356d2126e0743f7f229391577f0bb451bc180f2e3e  Documentation/devicetree/bindings/eeprom/at24.yaml\\n'\'' | sha256sum -c --strict"
  print "patch -p1 --fuzz=0 -i native-profile/src/camera/eeprom/0001-at24-readonly-vcc.patch"
  print "patch -p1 --fuzz=0 -i native-profile/src/camera/eeprom/0002-at24-readonly-vcc-binding.patch"
  print "install -m644 native-profile/src/camera/eeprom/at24-vcc-readonly.h drivers/nvmem/at24-vcc-readonly.h"
  print "rpm -q dt-schema"
  print "dt-doc-validate Documentation/devicetree/bindings/eeprom/at24.yaml"
  print
  next
 }
 /^uke_build_start=\$SECONDS$/ {
  print
  print "CC=clang bash native-profile/tests/at24-vcc731-contract.sh \"$PWD/native-generated/at24-before731\" \"$PWD\""
  print "CC=clang AT24_VCC_TEST_FLAGS='\''-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer'\'' bash native-profile/tests/at24-vcc731-contract.sh \"$PWD/native-generated/at24-before731\" \"$PWD\""
  print "CC=clang bash native-profile/tests/camera-nvmem-privacy731-contract.sh \"$PWD\""
  print "CC=clang CAMERA_NVMEM_TEST_FLAGS='\''-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer'\'' bash native-profile/tests/camera-nvmem-privacy731-contract.sh \"$PWD\""
  next
 }
 /^%check$/ {
  print
  print "test -s %{_uke_out}/drivers/nvmem/at24.o"
  print "llvm-readelf -h %{_uke_out}/drivers/nvmem/at24.o | grep -F AArch64"
  print "llvm-nm %{_uke_out}/drivers/nvmem/at24.o | awk '\''$NF==\"at24_read\" {found=1} END {exit !found}'\''"
  next
 }
 /^%changelog$/ {
  print
  print "* Wed Nov 04 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-" ENVIRON["UKE_CAMERA_BUILD_RELEASE"]
  print "- Add explicit read-only EEPROM voltage ownership and failure containment."
  print "- Preserve native CAMCC/CCI and keep EEPROM and sensor activation separate."
  print ""; next
 }
 {print}
' "$spec" > "$stage/next.spec"
mv "$stage/next.spec" "$spec"
[[ $(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec") == 7.3.1-$UKE_CAMERA_BUILD_RELEASE ]]
printf 'Prepared kernel %s with read-only at24 voltage qualification; EEPROM/sensor/capture DT remains inactive\n' "$UKE_CAMERA_BUILD_RELEASE"
