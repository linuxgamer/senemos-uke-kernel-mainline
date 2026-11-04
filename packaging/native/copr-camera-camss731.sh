#!/usr/bin/env bash
# COPR-only linked native SM7675 CAMSS source; no active camera DT or installation.
set -Eeuo pipefail
export LC_ALL=C
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?COPR result directory}")
export UKE_CAMERA_BUILD_RELEASE=${UKE_CAMERA_BUILD_RELEASE:-2000}
export UKE_CAMCC_PARENT_RELEASE=${UKE_CAMCC_PARENT_RELEASE:-1900}
[[ $UKE_CAMERA_BUILD_RELEASE =~ ^[1-9][0-9]{3,4}$ && $UKE_CAMERA_BUILD_RELEASE -ge 2000 ]]
bash "$owner/packaging/native/copr-camera-phy731.sh" "$output"
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
archive=senemos-native-profile-7.3.1.tar.xz
tar -tJf "$output/$archive" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
tar -xJf "$output/$archive" -C "$stage"
profile=$stage/native-profile
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS)
overlays=(src/camera/camss/0001-media-camss-return-phy-setup-errors.patch
 src/camera/camss/0002-media-camss-sm7675-resources.patch
 src/camera/camss/camss-sm7675-data.h src/camera/camss/camss-sm7675-phy-ops.h
 tests/camss-phy-stream731-contract.sh tests/fixtures/camss-phy-stream-check.c
 tests/camss-sm7675-linked731-check.sh tests/camss-sm7675-module731-object.sh)
for path in "${overlays[@]}"; do
 test ! -e "$profile/$path"
 install -Dm644 "$owner/$path" "$profile/$path"
done
# This document now describes both the prerequisite and the linked candidate.
cp "$owner/src/camera/camss/README731.md" "$profile/src/camera/camss/README731.md"
cp "$profile/source-composition.json" "$profile/source-composition-before-camss731.json"
api_hash=$(sha256sum "$profile/src/camera/camss/0001-media-camss-return-phy-setup-errors.patch")
profile_hash=$(sha256sum "$profile/src/camera/camss/0002-media-camss-sm7675-resources.patch")
jq --arg api_hash "${api_hash%% *}" --arg profile_hash "${profile_hash%% *}" '. + {
 source_mode:("retained"+.camera_base_release+"-with-native-sm7675-camss-module-and-uke-phy"),
 camss_parent_composition:"source-composition-before-camss731.json",
 native_phy_linked:true,native_phy_installed:true,native_camss_packaged:true,
 native_camss_match:true,native_camcc_linked:false,device_installation:false,
 camss_patch_inputs:[
  {path:"src/camera/camss/0001-media-camss-return-phy-setup-errors.patch",sha256:$api_hash},
  {path:"src/camera/camss/0002-media-camss-sm7675-resources.patch",sha256:$profile_hash}
 ],
 camera_provider_registered:false,camera_dt_activation:false,physical_acceptance:false
}' "$profile/source-composition-before-camss731.json" > "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
 -cJf "$output/$archive" -C "$stage" native-profile
spec=$output/senemos-uke-linux-kernel-mainline.spec
[[ $(grep -Fxc '%build' "$spec") == 1 ]]
awk '
 function literal_replace(line, from, to, at) {
  at=index(line,from)
  if(!at)return line
  replacements++
  return substr(line,1,at-1) to substr(line,at+length(from))
 }
 /^%build$/ {
  print "camss_dir=drivers/media/platform/qcom/camss"
  print "mkdir -p native-generated/camss-before731/$camss_dir"
  print "cp $camss_dir/camss-csiphy.c $camss_dir/camss-csiphy-3ph-1-0.c native-generated/camss-before731/$camss_dir/"
  print "patch -p1 --fuzz=0 -i native-profile/src/camera/camss/0001-media-camss-return-phy-setup-errors.patch"
  print "patch -p1 --fuzz=0 -i native-profile/src/camera/camss/0002-media-camss-sm7675-resources.patch"
  print "for header in csiphy-sm7675.h camss-sm7675-phy-ops.h camss-sm7675-data.h; do cp native-profile/src/camera/camss/$header $camss_dir/$header; done"
  print
  next
 }
 /^uke_build_start=\$SECONDS$/ {
  print
  print "CC=clang bash native-profile/tests/camss-phy-stream731-contract.sh \"$PWD/native-generated/camss-before731\" \"$PWD\""
  print "CC=clang CAMSS_STREAM_TEST_FLAGS='\''-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer'\'' bash native-profile/tests/camss-phy-stream731-contract.sh \"$PWD/native-generated/camss-before731\" \"$PWD\""
  next
 }
 /^%check$/ {
  print
  print "bash native-profile/tests/camss-sm7675-linked731-check.sh %{buildroot} '\''%{krel}'\''"
  next
 }
 /^bash boot-recipe\/src\/boot\/build-payload.sh / {
  print "bash native-profile/tests/camss-sm7675-module731-object.sh \"$PWD\" %{_uke_out} '\''%{krel}'\''"
 }
 {
  print literal_replace($0,"camss-sm7675-phy731-contract.sh \"$PWD\"", "camss-sm7675-phy731-contract.sh \"$PWD/native-generated/camss-before731\"")
 }
 END {if(replacements!=2)exit 1}
' "$spec" > "$stage/next.spec"
mv "$stage/next.spec" "$spec"
[[ $(grep -Fc 'bash native-profile/tests/camss-sm7675-module731-object.sh' "$spec") == 1 ]]
[[ $(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec") == 7.3.1-$UKE_CAMERA_BUILD_RELEASE ]]
printf 'Prepared kernel %s with linked SM7675 CAMSS profile and checked PHY setup; camera DT remains inactive\n' "$UKE_CAMERA_BUILD_RELEASE"
