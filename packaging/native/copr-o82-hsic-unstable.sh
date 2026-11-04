#!/usr/bin/env bash
# COPR only: retain installed7300 and qualify composed HSIC/SixZone in the unstable family.
set -Eeuo pipefail
trap 'o82_source_status=$?; printf "O82 source preparation failed at line %s (status%s)\n" "$LINENO" "$o82_source_status" >&2; exit "$o82_source_status"' ERR
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?Pass the remote source result directory}")
revision=${2:?Pass a fresh kernel revision of at least 10001}
[[ $revision =~ ^[1-9][0-9]{3,4}$ && $revision -ge 10001 ]]
manifest=manifests/o82-hsic-unstable-source-20261104.json
jq -e '(.delivery_held // false)==false' "$owner/$manifest" >/dev/null || {
    printf 'Color source is held: preserve the newer installed camera boot trial and review cumulative source first\n' >&2
    exit 1
}
(cd "$owner"; jq -r '.imports[]|.sha256+"  "+.path' "$manifest" | sha256sum -c --strict --quiet -)
(cd "$owner"; jq -r '.qualified_profile_compiler.inputs[]|.sha256+"  "+.path' "$manifest" | sha256sum -c --strict --quiet -)
# Admit the qualified complete7300 source by its full-file digest, RPM
# identity, exact source commit and retained profile/boot/configuration receipts.
for pair in 11253922:uke-o82-color-profile:0.5.0-1 11259919:senemos-uke-linux-kernel-mainline-unstable:7.3.1-7300; do
    build=${pair%%:*} rest=${pair#*:}
    name=${rest%%:*} version=${rest#*:}
    curl -fsSL --max-time 45 "https://copr.fedorainfracloud.org/api_3/build/$build" | \
        jq -e --arg name "$name" --arg version "$version" \
        '.state=="succeeded" and .source_package.name==$name and .source_package.version==$version' >/dev/null
done
curl -fsSL --max-time 45 https://copr.fedorainfracloud.org/api_3/build/source-build-config/11253922 | \
    jq -e '.source_dict.script | contains("commit=d10c0e35649c96d4e6f92316e75948cd51116784\n")' >/dev/null
bash "$owner/packaging/native/refuse-published-release.sh" \
    senemos-uke-linux-kernel-mainline-unstable "7.3.1-$revision"
[[ ! -e $output || (-d $output && -z $(find "$output" -mindepth 1 -maxdepth 1 -print -quit)) ]]
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
parent_url=$(jq -er .kernel_parent.url "$owner/$manifest")
parent_hash=$(jq -er .kernel_parent.sha256 "$owner/$manifest")
curl -fLsS --retry 2 --max-time 1200 --proto '=https' --proto-redir '=https' \
    "$parent_url" -o "$stage/parent.src.rpm"
printf '%s  %s\n' "$parent_hash" "$stage/parent.src.rpm" | sha256sum -c --strict -
[[ $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$stage/parent.src.rpm") == senemos-uke-linux-kernel-mainline-unstable-7.3.1-7300.fc46 ]]
rpmkeys --checksig --nosignature --verbose "$stage/parent.src.rpm"
rpm2cpio "$stage/parent.src.rpm" > "$stage/parent.cpio"
cpio -t --quiet < "$stage/parent.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/parent.cpio")
spec=$output/senemos-uke-linux-kernel-mainline-unstable.spec
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
[[ $(cat "$profile/source-commit") == bf1f6634bafc214219de1c48b3fc72a181485343 ]]
(cd "$profile"; sha256sum -c --strict --quiet SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --strict --quiet -)
cmp "$boot/lock.json" "$output/boot-payload.json"
cmp "$profile/native.config" "$boot/packaging/native/native.config"
composition_hash=$(jq -er .kernel_parent.composition_sha256 "$owner/$manifest")
printf '%s  %s\n' "$composition_hash" "$profile/source-composition.json" | sha256sum -c --strict -
# The qualified camera controller appends CONFIG_SM_CAMCC_7675=y. Its raw
# configuration digest is recorded by the fully pinned parent's composition.
native_config_hash=$(jq -er .native_config_sha256 "$profile/source-composition.json")
[[ $native_config_hash =~ ^[0-9a-f]{64}$ ]]
printf 'Retained raw native configuration SHA-256: %s\n' "$native_config_hash"
printf '%s  %s\n' "$native_config_hash" \
    "$profile/native.config" | sha256sum -c --strict -
printf '%s  %s\n' f81f42c2622a6eb671fd7ca11fbb0ce700b6f5a7589a43cb379b5baa7cdfb1ca \
    "$profile/src/input/nt36532-uke-protocol.c" | sha256sum -c --strict -
jq -e '.source_mode=="withdrawn6000-with-isolated-boot-admission-bisection" and
 .kernel_release=="7.3.1-7300-unstable" and .diagnostic_camera_stage==0 and
 .diagnostic_producer_commit=="00ebf622ca473b9b7a799b2f531b4871ddc70497" and
 .diagnostic_pstore_panic_layout and (.camcc_boot_fdt_activation|not) and
 .rtc_backend=="pmic-read-only-counter" and .rtc_offset_write_readback==false and
 .rtc_secure_offset_boot_activation==false and .rtc_secure_provider_qualified==false and
 .rtc_utc_calendar_qualified==false and
 (.o82_color_initial_preset // "")=="" and .native_ssc_iio_abi==1 and
 (.front_geni_dt_activation|not) and (.front_eeprom_dt_activation|not) and .front_eeprom_read_only and
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
# Retain the one preparation call and PA flush patches from qualified7300;
# the updated helper also stages the new shared HSIC format.
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
# The parent has a compact ABI-specific audio identity. Change exactly those
# two literals while retaining the UCM installer, topology and electrical data.
audio_path=src/audio/uke-audio-card.c
audio_release="7.3.1-$revision"u
audio_driver=$(printf 'uke%s' "$audio_release" | tr '.' '_')
[[ $(printf '%s' "$audio_driver" | wc -c) -lt 16 ]]
for tree in "$profile" "$boot"; do
    if [[ ! -f $tree/$audio_path ]]; then
        [[ $tree == "$boot" ]]
        install -Dm644 "$profile/$audio_path" "$tree/$audio_path"
        continue
    fi
    [[ $(grep -Fo 'uke7.3.1-7300u' "$tree/$audio_path" | wc -l) == 2 ]]
    sed "s/uke7[.]3[.]1-7300u/uke$audio_release/g" "$tree/$audio_path" > "$stage/audio-card.c"
    install -m644 "$stage/audio-card.c" "$tree/$audio_path"
done
printf '%s\n' "$audio_path" >> "$stage/overlays"
digest=$(sha256sum "$boot/$audio_path"); digest=$(cut -d ' ' -f1 <<< "$digest")
jq --arg path "$audio_path" --arg digest "$digest" \
    'if any(.source_assets[];.path==$path) then
       (.source_assets[]|select(.path==$path)|.sha256)=$digest
     else .source_assets += [{path:$path,sha256:$digest}] end' \
    "$boot/lock.json" > "$stage/audio-lock.json"
install -m644 "$stage/audio-lock.json" "$boot/lock.json"
bash "$profile/src/audio/desktop/install-policy.sh" "$stage/audio-policy-probe" "7.3.1-$revision-unstable"
[[ -d $stage/audio-policy-probe/usr/share/alsa/ucm2/Qualcomm/$audio_driver ]]
[[ -r $stage/audio-policy-probe/usr/share/alsa/ucm2/conf.d/$audio_driver/POCO-Pad-X1.conf ]]
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
cp "$profile/source-composition.json" "$profile/source-composition-before10000.json"
install -Dm644 "$owner/$manifest" "$profile/$manifest"
commit=$(git -C "$owner" rev-parse HEAD)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq -Rn '[inputs]' < "$stage/overlays" > "$stage/overlays.json"
jq --arg commit "$commit" --arg revision "$revision" --arg hash "$parent_hash" --arg audio "$audio_driver" \
    --slurpfile overlays "$stage/overlays.json" '
 del(.qualified_o82_kms_check,.qualified_o82_source_commit,
     .qualified_o82_sixzone_utility_check,.qualified_o82_sixzone_utility_source) + {
 source_commit:$commit,kernel_release:("7.3.1-"+$revision+"-unstable"),rpm_revision:$revision,
 package_family:"senemos-uke-linux-kernel-mainline-unstable",kernel_abi_suffix:"-unstable",
 diagnostic_audio_driver:$audio,normal_kernel_promotion:false,
 source_mode:"unstable7300-with-composed-hsic-sixzone-v4-color-caller",
 parent_copr_build:11259919,parent_srpm_sha256:$hash,
 parent_source_commit:"bf1f6634bafc214219de1c48b3fc72a181485343",
 parent_producer_commit:"00ebf622ca473b9b7a799b2f531b4871ddc70497",
 parent_composition:"source-composition-before10000.json",overlays:$overlays[0],
 o82_atomic_source_manifest:"manifests/o82-hsic-unstable-source-20261104.json",
 historical_o82_kms_check:11253082,
 historical_o82_kms_source_commit:"48aa87956b9d59c09dd8e0a82279c757cd59fb03",
 qualified_o82_profile_utility_check:11253922,
 qualified_o82_profile_utility_source:"d10c0e35649c96d4e6f92316e75948cd51116784",
 o82_after_reference_changes:["explicit HSIC v4 data and composed paired HSIC/SixZone ownership"],
 o82_private_color_bundle_version:4,o82_sixzone_software_support:true,
 o82_hsic_software_support:true,o82_explicit_neutral_hsic:true,
 o82_lutbus_max_bytes:41320,o82_shared_pa_flush_bit:0,
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
 "drivers/gpu/drm/msm/disp/dpu1/o82-hsic-format.h",
 "drivers/gpu/drm/msm/disp/dpu1/uke-o82-hdr-format.h"],
 native_hdr_advertised:false,device_installation:false,physical_acceptance:false
}' "$profile/source-composition-before10000.json" > "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --strict --quiet -)
for tree in native-profile boot-recipe; do
    archive=$native_archive
    [[ $tree != boot-recipe ]] || archive=$boot_archive
    tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
        -cJf "$output/$archive" -C "$stage/unpacked" "$tree"
done
install -m644 "$boot/lock.json" "$output/boot-payload.json"
[[ $(grep -Fxc '%global senemos_build_release 7300' "$spec") == 1 && $(grep -Fxc '%check' "$spec") == 1 ]]
# Preserve all parent checks; add the new color checks only when absent.
[[ $(grep -Fxc '%build' "$spec") == 1 ]]
[[ $(awk '/^%check$/{f=1;next} /^%files/{f=0} f&&/^bash native-profile\/tests\/unstable-boot-family731-contract.sh /{n++} END{print n+0}' "$spec") == 1 ]]
cat > "$stage/color-checks" <<'CHECKS'
bash native-profile/tests/o82-profile-loader-contract.sh native-profile
bash native-profile/tests/o82-lutbus-contract.sh
bash native-profile/tests/o82-regdma-transport-contract.sh native-profile "$PWD"
bash native-profile/tests/o82-atomic-contract.sh native-profile "$PWD"
bash native-profile/tests/o82-atomic-package-contract.sh "$PWD" %{_uke_out}
CHECKS
: > "$stage/missing-color-checks"
while IFS= read -r command; do
    prefix=$(cut -d ' ' -f1-2 <<< "$command")
    count=$(awk -v command="$prefix" '
        /^%(prep|build|install|check|files|changelog)([[:space:]]|$)/ {active=($0=="%check")}
        active && ($0==command || index($0,command" ")==1) {count++}
        END {print count+0}' "$spec")
    [[ $count == 0 || $count == 1 ]]
    [[ $count == 1 ]] || printf '%s\n' "$command" >> "$stage/missing-color-checks"
done < "$stage/color-checks"
awk -v revision="$revision" -v checks="$stage/missing-color-checks" '
 BEGIN {while((getline line < checks)>0) extra[++n]=line;close(checks)}
 /^%build$/ {
  print "# Final-source controls after the new paired color patches."
  print "CC=clang bash native-profile/tests/o82-avr-contract.sh \"$PWD\""
  print "CXX=clang++ bash native-profile/tests/dpu-video-timing-contract.sh \"$PWD\""
  print "CC=clang bash native-profile/tests/msm-retirement-proof-contract.sh \"$PWD\""
  print "CC=clang bash native-profile/tests/dpu-reservation-contract.sh \"$PWD\" \"$PWD/native-generated/dpu-reservation-before56\""
  print "CC=clang bash native-profile/tests/dpu-color-topology-contract.sh \"$PWD/drivers/gpu/drm/msm/disp/dpu1/dpu_crtc.c\""
  print "bash native-profile/tests/o82-profile-loader-contract.sh native-profile"
  print "bash native-profile/tests/o82-lutbus-contract.sh"
  print "bash native-profile/tests/o82-regdma-transport-contract.sh native-profile \"$PWD\""
  print "bash native-profile/tests/o82-atomic-contract.sh native-profile \"$PWD\""
  print "printf '\''Final-source unstable v4 color and retained display preflight passed\\n'\''"
 }
 /^%check$/ {checking=1}
 checking && /^%files($|[[:space:]])/ {for(i=1;i<=n;i++)print extra[i];checking=0}
 /^%global senemos_build_release 7300$/ {$0="%global senemos_build_release "revision}
 /Final-source v3 loader/ {gsub(/Final-source v3 loader/, "Final-source v4 loader")}
 /^%changelog$/ {
  print;print "* Wed Nov 04 2026 Uke contributors - 7.3.1-"revision
  print "- Retain the complete 7300 camera, touch, sensor, power and display sources."
  print "- Add explicit HSIC v4 data and compose paired HSIC/SixZone state with readback."
  print "- Preserve disabled initial selection and require matching private v4 input."
  print "- Verify full module linkage, failure ownership and both supplier DTs."
  print "- Exercise color refusal in retained AVR, video, retirement and reservation fixtures."
  print "";next
 }
 {print}
' "$spec" > "$stage/next.spec"
install -m644 "$stage/next.spec" "$spec"
sha256sum -c --quiet "$stage/retained-sources.sha256"
[[ $(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec") == 7.3.1-$revision ]]
bash "$owner/tests/unstable-boot-family731-contract.sh" "$spec"
printf 'Complete retained kernel source prepared with the qualified v4 profile compiler; full kernel qualification pending and default selection disabled, physical camera/pen/color/HDR acceptance remains open\n'
