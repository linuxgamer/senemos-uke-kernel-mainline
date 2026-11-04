#!/usr/bin/env bash
# COPR only. First guarded controller activation; full camera graph stays open.
set -Eeuo pipefail
export LC_ALL=C
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?COPR result directory}")
export UKE_CAMERA_BUILD_RELEASE=${UKE_CAMERA_BUILD_RELEASE:-2000}
[[ $UKE_CAMERA_BUILD_RELEASE =~ ^[1-9][0-9]{3,4}$ && $UKE_CAMERA_BUILD_RELEASE -ge 2000 ]]
bash "$owner/packaging/native/copr-camera-camss731.sh" "$output"
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
test -f "$profile/src/boot/uke-abl.c"
overlays=(src/camera/provider/0005-clk-qcom-build-native-sm7675.patch
 src/camera/provider/uke-camcc-dt.h src/camera/provider/camcc-abl-hook.patch
 src/camera/provider/camcc-scope-hook.patch
 src/camera/provider/camcc-prepare-hook.patch src/camera/prepare-controller731.sh
 tests/camcc-controller-fdt731-contract.sh tests/fixtures/camcc-controller-fdt-check.c
 tests/camcc-controller-linked731-check.sh src/camera/provider/CONTROLLER731.md)
for path in "${overlays[@]}"; do
 test ! -e "$profile/$path"
 install -Dm644 "$owner/$path" "$profile/$path"
done
for tree in "$profile" "$boot"; do
 printf 'Retained controller hook inputs: %s\n' "${tree##*/}"
 sha256sum "$tree/src/boot/prepare-abl-source.sh"
 test ! -e "$tree/src/boot/uke-camcc-dt.h"
 install -m644 "$owner/src/camera/provider/uke-camcc-dt.h" "$tree/src/boot/uke-camcc-dt.h"
 if [[ -f $tree/src/boot/uke-abl.c ]]; then
  git -C "$tree" apply --check "$owner/src/camera/provider/camcc-abl-hook.patch"
  git -C "$tree" apply "$owner/src/camera/provider/camcc-abl-hook.patch"
  [[ $(grep -Fxc '#include "uke-camcc-dt.h"' "$tree/src/boot/uke-abl.c") == 1 ]]
 fi
 git -C "$tree" apply --check "$owner/src/camera/provider/camcc-prepare-hook.patch"
 git -C "$tree" apply "$owner/src/camera/provider/camcc-prepare-hook.patch"
 [[ $(grep -Fxc 'install -m644 "$here/uke-camcc-dt.h" "$kernel/arch/arm64/kernel/uke-camcc-dt.h"' "$tree/src/boot/prepare-abl-source.sh") == 1 ]]
 # Retained preparation includes producer-added SSC hooks beyond the repository
 # preimage. Append the digest after those hooks without requiring an old EOF.
 ! grep -Fq 'sha256sum "$here/uke-camcc-dt.h"' "$tree/src/boot/prepare-abl-source.sh"
 printf '\n%s\n' 'sha256sum "$here/uke-camcc-dt.h" >> "$output/abl-source-SHA256SUMS"' >> "$tree/src/boot/prepare-abl-source.sh"
 bash -n "$tree/src/boot/prepare-abl-source.sh"
 git -C "$tree" apply --check "$owner/src/camera/provider/camcc-scope-hook.patch"
 git -C "$tree" apply "$owner/src/camera/provider/camcc-scope-hook.patch"
done
cmp "$profile/native.config" "$boot/packaging/native/native.config"
! grep -q '^CONFIG_SM_CAMCC_7675=' "$profile/native.config"
printf '\nCONFIG_SM_CAMCC_7675=y\n' >> "$profile/native.config"
cp "$profile/native.config" "$boot/packaging/native/native.config"
for path in src/boot/uke-camcc-dt.h src/boot/prepare-abl-source.sh src/boot/uke-abl.c packaging/native/native.config tests/uke-build-scope-contract.sh; do
 test -f "$boot/$path" || continue
 digest=$(sha256sum "$boot/$path"); digest=${digest%% *}
 jq --arg path "$path" --arg digest "$digest" \
  '.source_assets |= (map(select(.path!=$path)) + [{path:$path,sha256:$digest}])' \
  "$boot/lock.json" > "$stage/next-lock.json"
 mv "$stage/next-lock.json" "$boot/lock.json"
done
cp "$boot/lock.json" "$output/boot-payload.json"
cp "$profile/source-composition.json" "$profile/source-composition-before-controller731.json"
config_hash=$(sha256sum "$profile/native.config"); config_hash=${config_hash%% *}
jq --arg digest "$config_hash" '. + {
 source_mode:("retained"+.camera_base_release+"-with-guarded-native-camcc-and-camss"),
 controller_parent_composition:"source-composition-before-controller731.json",
 native_provider_linked:true,native_provider_installed:true,native_camcc_linked:true,
 gdsc_permanent_storage_callers:1,controller_pm_domains_opted_in:8,
 camcc_boot_fdt_activation:true,camera_dt_activation:true,camera_sensor_dt_activation:false,
 camera_capture_graph_activation:false,camera_provider_registered:false,
 changed_kernel_files:((.changed_kernel_files + [
  "drivers/clk/qcom/Kconfig","drivers/clk/qcom/Makefile",
  "drivers/clk/qcom/camcc-sm7675.c","drivers/clk/qcom/camcc-sm7675-data.h",
  "drivers/clk/qcom/provider/camcc-sm7675-power.h","drivers/clk/qcom/provider/camcc-sm7675-owner.h",
  "drivers/clk/qcom/provider/camcc-sm7675-clocks.h","drivers/clk/qcom/provider/camcc-sm7675-handoff.h",
  "drivers/clk/qcom/provider/camcc-sm7675-registration.h","drivers/clk/qcom/provider/camcc-sm7675-crm-guard.h",
  "include/dt-bindings/clock/qcom,sm7675-camcc.h",
  "arch/arm64/kernel/uke-abl.c","arch/arm64/kernel/uke-camcc-dt.h",
  "drivers/media/platform/qcom/camss/camss-csiphy.c",
  "drivers/media/platform/qcom/camss/camss-csiphy.h",
  "drivers/media/platform/qcom/camss/camss-csiphy-2ph-1-0.c",
  "drivers/media/platform/qcom/camss/camss-csiphy-3ph-1-0.c",
  "drivers/media/platform/qcom/camss/camss-vfe.c","drivers/media/platform/qcom/camss/camss.c",
  "drivers/media/platform/qcom/camss/camss.h","drivers/media/platform/qcom/camss/csiphy-sm7675.h",
  "drivers/media/platform/qcom/camss/camss-sm7675-phy-ops.h",
  "drivers/media/platform/qcom/camss/camss-sm7675-data.h"
 ])|unique),
 native_config_sha256:$digest,device_installation:false,physical_acceptance:false
}' "$profile/source-composition-before-controller731.json" > "$profile/source-composition.json"
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
 /^%build$/ {print "bash native-profile/src/camera/prepare-controller731.sh \"$PWD\"";print;next}
 /^uke_build_start=\$SECONDS$/ {
  print
  print "CC=clang bash native-profile/tests/camcc-controller-fdt731-contract.sh"
  print "CC=clang CAMCC_FDT_TEST_FLAGS='\''-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer'\'' bash native-profile/tests/camcc-controller-fdt731-contract.sh"
  next
 }
 /^%check$/ {
  print
  print "bash native-profile/tests/camcc-controller-linked731-check.sh %{_uke_out} %{buildroot} '\''%{krel}'\''"
  next
 }
 /^%changelog$/ {
  print
  print "* Wed Nov 04 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-" ENVIRON["UKE_CAMERA_BUILD_RELEASE"]
  print "- Link permanent Uke CAMCC with read-only CRM mode admission."
  print "- Activate only the controller graph and contain unported OEM camera consumers."
  print "- Preserve the secure RTC/SSC parent and keep full camera acceptance outstanding."
  print "";next
 }
 {print}
' "$spec" > "$stage/next.spec"
mv "$stage/next.spec" "$spec"
[[ $(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec") == 7.3.1-$UKE_CAMERA_BUILD_RELEASE ]]
printf 'Prepared %s with guarded permanent CAMCC and controller-only boot FDT; sensor/EEPROM/focus/capture and full physical acceptance remain open\n' "$UKE_CAMERA_BUILD_RELEASE"
