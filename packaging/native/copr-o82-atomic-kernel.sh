#!/usr/bin/env bash
# COPR only: retain6503 and qualify paired atomic SixZone/PA integration.
set -Eeuo pipefail
trap 'o82_source_status=$?; printf "O82 source preparation failed at line %s (status%s)\n" "$LINENO" "$o82_source_status" >&2; exit "$o82_source_status"' ERR
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?Pass the remote source result directory}")
revision=${2:?Pass a fresh kernel revision of at least 7002}
[[ $revision =~ ^[1-9][0-9]{3,4}$ && $revision -ge 7002 ]]
manifest=manifests/o82-sixzone-kernel-source-20261104.json
(cd "$owner"; jq -r '.imports[]|.sha256+"  "+.path' "$manifest" | sha256sum -c --strict --quiet -)
(cd "$owner"; jq -r '.qualified_sixzone_compiler.inputs[]|.sha256+"  "+.path' "$manifest" | sha256sum -c --strict --quiet -)
# Admit the complete6503 source by its full-file digest, RPM identity and
# profile/boot receipts. The preceding6000 repository artifact now returns404;
# do not substitute a different archive under its old digest.
for pair in 11253576:uke-o82-color-profile:0.4.0-1; do
    build=${pair%%:*} rest=${pair#*:}
    name=${rest%%:*} version=${rest#*:}
    curl -fsSL --max-time 45 "https://copr.fedorainfracloud.org/api_3/build/$build" | \
        jq -e --arg name "$name" --arg version "$version" \
        '.state=="succeeded" and .source_package.name==$name and .source_package.version==$version' >/dev/null
done
curl -fsSL --max-time 45 https://copr.fedorainfracloud.org/api_3/build/source-build-config/11253576 | \
    jq -e '.source_dict.script | contains("commit=33035dff7573775fb5f7ae7e3909e36451043899\n")' >/dev/null
bash "$owner/packaging/native/refuse-published-release.sh" \
    senemos-uke-linux-kernel-mainline "7.3.1-$revision"
[[ ! -e $output || (-d $output && -z $(find "$output" -mindepth 1 -maxdepth 1 -print -quit)) ]]
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
parent_url=$(jq -er .kernel_parent.url "$owner/$manifest")
parent_hash=$(jq -er .kernel_parent.sha256 "$owner/$manifest")
curl -fLsS --retry 2 --max-time 1200 --proto '=https' --proto-redir '=https' \
    "$parent_url" -o "$stage/parent.src.rpm"
printf '%s  %s\n' "$parent_hash" "$stage/parent.src.rpm" | sha256sum -c --strict -
[[ $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$stage/parent.src.rpm") == senemos-uke-linux-kernel-mainline-7.3.1-6503.fc46 ]]
rpmkeys --checksig --nosignature --verbose "$stage/parent.src.rpm"
rpm2cpio "$stage/parent.src.rpm" > "$stage/parent.cpio"
cpio -t --quiet < "$stage/parent.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/parent.cpio")
spec=$output/senemos-uke-linux-kernel-mainline.spec
native_archive=senemos-native-profile-7.3.1.tar.xz
boot_archive=senemos-uke-boot-recipe.tar.xz
find "$output" -maxdepth 1 -type f ! -name "${spec##*/}" \
    ! -name "$native_archive" ! -name "$boot_archive" ! -name boot-payload.json \
    -print0 | sort -z | xargs -0 sha256sum > "$stage/retained-sources.sha256"
for archive in "$native_archive" "$boot_archive"; do
    tar -tJf "$output/$archive" > "$stage/entries"
    awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
    tar -xJf "$output/$archive" -C "$stage/unpacked"
done
profile=$stage/unpacked/native-profile
boot=$stage/unpacked/boot-recipe
[[ $(cat "$profile/source-commit") == 90b8c9c89f8c89475c5a371f58dc7c7c88e29911 ]]
(cd "$profile"; sha256sum -c --strict --quiet SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --strict --quiet -)
cmp "$boot/lock.json" "$output/boot-payload.json"
cmp "$profile/native.config" "$boot/packaging/native/native.config"
# The qualified camera controller appends CONFIG_SM_CAMCC_7675=y. Its raw
# configuration digest is recorded by the fully pinned parent's composition.
native_config_hash=$(jq -er .native_config_sha256 "$profile/source-composition.json")
[[ $native_config_hash =~ ^[0-9a-f]{64}$ ]]
printf 'Retained raw native configuration SHA-256: %s\n' "$native_config_hash"
printf '%s  %s\n' "$native_config_hash" \
    "$profile/native.config" | sha256sum -c --strict -
printf '%s  %s\n' f81f42c2622a6eb671fd7ca11fbb0ce700b6f5a7589a43cb379b5baa7cdfb1ca \
    "$profile/src/input/nt36532-uke-protocol.c" | sha256sum -c --strict -
jq -e '.source_mode=="retained6000-with-qualified-paired-atomic-color-caller" and
 .kernel_release=="7.3.1-6503" and .o82_atomic_color_caller and
 .o82_color_initial_preset=="" and .native_ssc_iio_abi==1 and
 .front_geni_dt_activation and .front_eeprom_dt_activation and .front_eeprom_read_only and
 .front_eeprom_size==8192 and (.camera_sensor_dt_activation|not) and
 (.camera_capture_graph_activation|not) and (.rear_eeprom_dt_activation|not) and
 (.calibration_consumed|not) and (.rear_focus|not) and
 .touch_gesture_setting_path=="OEM-mandatory-ACK-without-extra-getters" and
 .touch_coordinate_readback_preserved and .touch_mandatory_errors_preserved and
 .touch_panel_order_unchanged and .ath11k_regulatory_policy_unchanged and
 .panel_variants==["o82_36_02_0a","o82_42_02_0b"] and
 .touch_variants==["tianma","csot"] and (.o82_color_dma_enabled|not) and
 (.native_hdr_advertised|not) and (.physical_acceptance|not)' \
    "$profile/source-composition.json" >/dev/null
# This one inherited call follows the retained retirement patches and applies
# 0072 for the first time. Updating its source also adds 0073--0076 there.
[[ $(grep -Fxc 'bash "$profile/src/display/prepare-o82-regdma.sh" "$kernel"' "$profile/prepare.sh") == 1 ]]
cp "$profile/SHA256SUMS" "$stage/parent-profile.sha256"
cp "$boot/lock.json" "$stage/parent-boot-lock.json"
(cd "$boot"; find . -type f ! -name lock.json -print0 | sort -z | xargs -0 sha256sum) > "$stage/parent-boot.sha256"
jq -r '.imports[].path' "$owner/$manifest" > "$stage/overlays"
while read -r relative; do
    [[ $relative =~ ^(src|tests|patches)/[a-zA-Z0-9_,./-]+$ && $relative != *..* ]]
    install -Dm644 "$owner/$relative" "$profile/$relative"
    install -Dm644 "$owner/$relative" "$boot/$relative"
    digest=$(sha256sum "$boot/$relative"); digest=${digest%% *}
    jq --arg path "$relative" --arg digest "$digest" \
        'if any(.source_assets[];.path==$path) then
          (.source_assets[]|select(.path==$path)|.sha256)=$digest
         else .source_assets += [{path:$path,sha256:$digest}] end' \
        "$boot/lock.json" > "$stage/lock.json"
    install -m644 "$stage/lock.json" "$boot/lock.json"
done < "$stage/overlays"
while read -r expected relative; do
    relative=${relative#./}
    case $relative in source-commit|source-composition.json) continue;; esac
    if ! grep -Fxq "$relative" "$stage/overlays"; then
        printf '%s  %s\n' "$expected" "$profile/$relative" | sha256sum -c --quiet -
    fi
done < "$stage/parent-profile.sha256"
while read -r expected relative; do
    relative=${relative#./}
    if ! grep -Fxq "$relative" "$stage/overlays"; then
        printf '%s  %s\n' "$expected" "$boot/$relative" | sha256sum -c --quiet -
    fi
done < "$stage/parent-boot.sha256"
cmp <(jq -S 'del(.source_assets)' "$stage/parent-boot-lock.json") \
    <(jq -S 'del(.source_assets)' "$boot/lock.json")
# Preserve every old asset entry; additions are restricted to declared imports.
jq -e --slurpfile old "$stage/parent-boot-lock.json" --rawfile overlays "$stage/overlays" '
 ($overlays|split("\n")|map(select(length>0))) as $allowed |
 [.source_assets[].path] as $paths |
 all($old[0].source_assets[]; .path as $p | $paths|index($p)!=null) and
 all(.source_assets[]; .path as $p |
   any($old[0].source_assets[];.path==$p) or ($allowed|index($p)!=null)) and
 ((.source_assets|map(.path)|length)==(.source_assets|map(.path)|unique|length))' \
    "$boot/lock.json" >/dev/null
cp "$profile/source-composition.json" "$profile/source-composition-before7000.json"
install -Dm644 "$owner/$manifest" "$profile/$manifest"
commit=$(git -C "$owner" rev-parse HEAD)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq -Rn '[inputs]' < "$stage/overlays" > "$stage/overlays.json"
jq --arg commit "$commit" --arg revision "$revision" --arg hash "$parent_hash" \
    --slurpfile overlays "$stage/overlays.json" '. + {
 source_commit:$commit,kernel_release:("7.3.1-"+$revision),rpm_revision:$revision,
 source_mode:"retained6503-with-paired-sixzone-v3-color-caller",
 parent_copr_build:11253343,parent_srpm_sha256:$hash,
 parent_source_commit:"90b8c9c89f8c89475c5a371f58dc7c7c88e29911",
 parent_composition:"source-composition-before7000.json",overlays:$overlays[0],
 o82_atomic_source_manifest:"manifests/o82-sixzone-kernel-source-20261104.json",
 qualified_o82_kms_check:11253082,
 qualified_o82_source_commit:"48aa87956b9d59c09dd8e0a82279c757cd59fb03",
 qualified_o82_sixzone_utility_check:11253576,
 qualified_o82_sixzone_utility_source:"33035dff7573775fb5f7ae7e3909e36451043899",
 o82_after_reference_changes:["bounded SixZone v3 firmware and paired shared PA ownership"],
 o82_private_color_bundle_version:3,o82_sixzone_software_support:true,
 o82_lutbus_max_bytes:41288,o82_shared_pa_flush_bit:0,
 o82_final_kernel_qualification_required:true,
 o82_atomic_color_caller:true,o82_color_initial_preset:"",
 o82_color_private_firmware_required:true,o82_color_dma_enabled:false,
 kernel_driver_source_unchanged:false,
 o82_atomic_additional_kernel_files:[
 "drivers/gpu/drm/msm/disp/dpu1/dpu_crtc.c",
 "drivers/gpu/drm/msm/disp/dpu1/dpu_crtc.h",
 "drivers/gpu/drm/msm/disp/dpu1/dpu_encoder.c",
 "drivers/gpu/drm/msm/disp/dpu1/dpu_hw_catalog.h",
 "drivers/gpu/drm/msm/disp/dpu1/dpu_hw_ctl.c",
 "drivers/gpu/drm/msm/disp/dpu1/dpu_o82_color.c",
 "drivers/gpu/drm/msm/disp/dpu1/dpu_o82_color.h",
 "drivers/gpu/drm/msm/disp/dpu1/dpu_o82_power.c",
 "drivers/gpu/drm/msm/disp/dpu1/dpu_o82_power.h",
 "drivers/gpu/drm/msm/disp/dpu1/dpu_o82_upload.c",
 "drivers/gpu/drm/msm/disp/dpu1/dpu_o82_upload.h",
 "drivers/gpu/drm/msm/disp/dpu1/dpu_o82_lutbus.c",
 "drivers/gpu/drm/msm/disp/dpu1/dpu_o82_lutbus.h",
 "drivers/gpu/drm/msm/disp/dpu1/dpu_o82_profiles.c",
 "drivers/gpu/drm/msm/disp/dpu1/dpu_o82_profiles.h",
 "drivers/gpu/drm/msm/disp/dpu1/o82-color-firmware.h",
 "drivers/gpu/drm/msm/disp/dpu1/o82-sixzone-format.h",
 "drivers/gpu/drm/msm/disp/dpu1/uke-o82-hdr-format.h"],
 native_hdr_advertised:false,device_installation:false,physical_acceptance:false
}' "$profile/source-composition-before7000.json" > "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --strict --quiet -)
for tree in native-profile boot-recipe; do
    archive=$native_archive
    [[ $tree != boot-recipe ]] || archive=$boot_archive
    tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
        -cJf "$output/$archive" -C "$stage/unpacked" "$tree"
done
install -m644 "$boot/lock.json" "$output/boot-payload.json"
[[ $(grep -Fxc '%global senemos_build_release 6503' "$spec") == 1 && $(grep -Fxc '%check' "$spec") == 1 ]]
# The6503 spec runs AVR once in prep and once in check. Admit both original
# calls separately, preserving the final-source preflight and package check.
for section in prep check; do
    [[ $(awk -v section="$section" \
        -v command='CC=clang bash native-profile/tests/o82-avr-contract.sh "$PWD"' '
        /^%(prep|build|install|check|files|changelog)([[:space:]]|$)/ {active=($0=="%"section)}
        active && $0==command {count++}
        END {print count+0}' "$spec") == 1 ]]
done
[[ $(awk -v command='bash native-profile/tests/o82-atomic-package-contract.sh "$PWD" %{_uke_out}' '
    /^%(prep|build|install|check|files|changelog)([[:space:]]|$)/ {active=($0=="%check")}
    active && $0==command {count++}
    END {print count+0}' "$spec") == 1 ]]
awk -v revision="$revision" '
 /^%global senemos_build_release 6503$/ {$0="%global senemos_build_release "revision}
 /^%build$/ {
  print "# Check the new PA source after the retained final-source display fixtures."
  print "bash native-profile/tests/o82-profile-loader-contract.sh native-profile"
  print "bash native-profile/tests/o82-lutbus-contract.sh"
  print "bash native-profile/tests/o82-regdma-transport-contract.sh native-profile \"$PWD\""
  print "bash native-profile/tests/o82-atomic-contract.sh native-profile \"$PWD\""
  print "printf '\''Final-source v3 loader, LUTBUS, power and atomic PA preflight passed\\n'\''"
  print;next
 }
 /^%check$/ {
  print
  print "bash native-profile/tests/o82-profile-loader-contract.sh native-profile"
  next
 }
 /^%changelog$/ {
  print;print "* Wed Nov 04 2026 Uke contributors - 7.3.1-"revision
  print "- Retain the complete 6503 camera, touch, sensor, power and display sources."
  print "- Add bounded SixZone v3 tables and paired shared PA enable, disable and readback."
  print "- Preserve disabled initial selection and require matching private v3 input."
  print "- Verify full module linkage, failure ownership and both supplier DTs."
  print "- Exercise color refusal in retained AVR, video, retirement and reservation fixtures."
  print "";next
 }
 {print}
' "$spec" > "$stage/next.spec"
install -m644 "$stage/next.spec" "$spec"
sha256sum -c --quiet "$stage/retained-sources.sha256"
[[ $(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec") == 7.3.1-$revision ]]
printf 'Complete retained kernel source prepared with qualified paired color caller; default selection disabled, physical camera/pen/color/HDR acceptance remains open\n'
