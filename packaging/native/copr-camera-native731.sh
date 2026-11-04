#!/usr/bin/env bash
# COPR-only complete permanent-provider source qualification. No DT activation.
set -Eeuo pipefail
export LC_ALL=C
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?COPR result directory}")
export UKE_CAMERA_BUILD_RELEASE=${UKE_CAMERA_BUILD_RELEASE:-1206}
[[ $UKE_CAMERA_BUILD_RELEASE =~ ^[1-9][0-9]{3,4}$ && $UKE_CAMERA_BUILD_RELEASE -ge 1206 ]]
bash "$owner/packaging/native/copr-camera-storage731.sh" "$output"
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
archive=senemos-native-profile-7.3.1.tar.xz
tar -tJf "$output/$archive" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
tar -xJf "$output/$archive" -C "$stage"
profile=$stage/native-profile
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS)
overlays=(src/camera/camcc-sm7675.c src/camera/provider/camcc-sm7675-handoff.h
    src/camera/provider/camcc-sm7675-registration.h src/camera/provider/NATIVE731.md
    src/camera/provider/camcc-sm7675-crm-guard.h
    tests/camcc-native-object.sh tests/camcc-native731-contract.sh tests/fixtures/camcc-native-check.c
    tests/camcc-crm-guard731-contract.sh tests/fixtures/camcc-crm-guard-check.c)
for path in "${overlays[@]}"; do
    test ! -e "$profile/$path"
    install -Dm644 "$owner/$path" "$profile/$path"
done
cp "$profile/source-composition.json" "$profile/source-composition-before-native731.json"
jq '. + {
    source_mode:("retained"+(.camera_base_release // "1011")+"-with-complete-unlinked-native-camcc-source-and-sensors"),
    native_parent_composition:"source-composition-before-native731.json",
    native_provider_object:true,native_provider_linked:false,native_provider_installed:false,
    crm_mode_admission:true,crm_direct_programming_requires_disabled:true,
    camera_provider_registered:false,camera_dt_activation:false,physical_acceptance:false
}' "$profile/source-composition-before-native731.json" > "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
    -cJf "$output/$archive" -C "$stage" native-profile
spec=$output/senemos-uke-linux-kernel-mainline.spec
[[ $(grep -Fxc 'uke_build_start=$SECONDS' "$spec") == 1 ]]
awk '
 /^uke_build_start=\$SECONDS$/ {
  print
  print "CC=clang bash native-profile/tests/camcc-crm-guard731-contract.sh"
  print "CC=clang CAMCC_CRM_TEST_FLAGS='\''-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer'\'' bash native-profile/tests/camcc-crm-guard731-contract.sh"
  print "CC=clang bash native-profile/tests/camcc-native731-contract.sh \"$PWD\""
  print "CC=clang CAMCC_NATIVE_TEST_FLAGS='\''-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer'\'' bash native-profile/tests/camcc-native731-contract.sh \"$PWD\""
  next
 }
 /^bash boot-recipe\/src\/boot\/build-payload.sh / {
  print "bash native-profile/tests/camcc-native-object.sh \"$PWD\" %{_uke_out} boot-recipe/packaging/native/native.config '\''%{krel}'\''"
 }
 /^%check$/ {
  print
  print "test -z \"$(find %{buildroot} -type f \\( -name '\''*camcc-native*'\'' -o -name '\''*camcc-sm7675*'\'' \\) -print -quit)\""
  next
 }
 {print}
' "$spec" > "$stage/next.spec"
mv "$stage/next.spec" "$spec"
[[ $(grep -Fc 'bash native-profile/tests/camcc-native-object.sh' "$spec") == 1 ]]
[[ $(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec") == 7.3.1-$UKE_CAMERA_BUILD_RELEASE ]]
printf 'Prepared kernel %s with complete native provider source/model/object checks; no driver/DT activation\n' "$UKE_CAMERA_BUILD_RELEASE"
