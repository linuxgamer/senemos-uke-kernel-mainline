#!/usr/bin/env bash
# COPR only: retain qualified11003 and add read-only SSC discovery observations.
set -Eeuo pipefail
trap 'status=$?; printf "SSC cohort preparation failed at line %s (exit %s)\n" "$LINENO" "$status" >&2; exit "$status"' ERR
export LC_ALL=C
test ! -e /etc/senemos/kernel-update.conf
[[ $# == 2 && $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "$1")
revision=$2
[[ $revision =~ ^[1-9][0-9]{4}$ && $revision -ge 12000 ]]
manifest=manifests/ssc-observation-cohort-20261104.json
jq -e '(.delivery_held // false)==false' "$owner/$manifest" >/dev/null || {
    printf 'Historical SSC source is held; integrate current cumulative sources through the shared kernel queue\n' >&2
    exit 1
}
(cd "$owner"; jq -r '.imports[]|.sha256+"  "+.path' "$manifest" | sha256sum -c --strict --quiet -)
bash "$owner/packaging/native/refuse-published-release.sh" \
    senemos-uke-linux-kernel-mainline-unstable "7.3.1-$revision"
for pair in 11260288:senemos-uke-linux-kernel-mainline-unstable:7.3.1-11003 11260554:uke-ssc-protocol-check:1.0-10; do
    build=${pair%%:*} rest=${pair#*:}
    name=${rest%%:*} version=${rest#*:}
    curl -q -fsSL --max-time 45 "https://copr.fedorainfracloud.org/api_3/build/$build" | \
        jq -e --arg name "$name" --arg version "$version" \
        '.state=="succeeded" and .source_package.name==$name and .source_package.version==$version' >/dev/null
done
curl -q -fsSL --max-time 45 https://copr.fedorainfracloud.org/api_3/build/source-build-config/11260554 | \
    jq -e '.source_dict.script|contains("commit=afe3b4171cb552775d92561451db877bbb3732de\n")' >/dev/null
[[ ! -e $output || (-d $output && -z $(find "$output" -mindepth 1 -maxdepth 1 -print -quit)) ]]
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
parent_url=$(jq -er .kernel_parent.url "$owner/$manifest")
parent_hash=$(jq -er .kernel_parent.sha256 "$owner/$manifest")
curl -q -fLsS --retry 2 --max-time 600 --proto '=https' --proto-redir '=https' \
    "$parent_url" -o "$stage/parent.src.rpm"
printf '%s  %s\n' "$parent_hash" "$stage/parent.src.rpm" | sha256sum -c --strict -
[[ $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$stage/parent.src.rpm") == senemos-uke-linux-kernel-mainline-unstable-7.3.1-11003.fc46 ]]
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
[[ $(cat "$profile/source-commit") == 261d85e218906f78d37810db78a4aa80cd900067 ]]
(cd "$profile"; sha256sum -c --strict --quiet SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --strict --quiet -)
cmp "$boot/lock.json" "$output/boot-payload.json"
cmp "$profile/native.config" "$boot/packaging/native/native.config"
composition_hash=$(jq -er .kernel_parent.composition_sha256 "$owner/$manifest")
config_hash=$(jq -er .kernel_parent.native_config_sha256 "$owner/$manifest")
printf '%s  %s\n' "$composition_hash" "$profile/source-composition.json" \
    "$config_hash" "$profile/native.config" | sha256sum -c --strict -
jq -e '.kernel_release=="7.3.1-11003-unstable" and
 .source_mode=="rtc7300-hsic7600-cdsp7603-camcc8101-corrected-network8200-nfc-wakeup" and
 .diagnostic_camera_stage==1 and .camcc_boot_fdt_activation and
 .diagnostic_pstore_panic_layout and .rtc_backend=="pmic-read-only-counter" and
 (.rtc_secure_offset_boot_activation|not) and (.rtc_offset_write_readback|not) and
 .cdsp_start_stop_retention and (.cdsp_auto_boot|not) and .waydroid_network_precompile_config_gate and
 .nfc_wakeup_owner=="i2c-core" and .nfc_wake_irq_owner=="i2c-core" and
 .o82_private_color_bundle_version==4 and .o82_hsic_software_support and .o82_sixzone_software_support and
 .o82_color_initial_preset=="" and (.o82_color_dma_enabled|not) and (.native_hdr_advertised|not) and
 .native_ssc_iio_abi==1 and .ssc_adsp_supplier_bound_gate==1 and
 (.front_geni_dt_activation|not) and (.front_eeprom_dt_activation|not) and .front_eeprom_read_only and
 (.camera_sensor_dt_activation|not) and (.camera_capture_graph_activation|not) and
 (.calibration_consumed|not) and (.rear_focus|not) and
 .panel_variants==["o82_36_02_0a","o82_42_02_0b"] and
 .touch_variants==["tianma","csot"] and (.physical_acceptance|not)' \
    "$profile/source-composition.json" >/dev/null
# The qualified callbacks must retain exactly the tested wire and build interface.
(cd "$profile"; jq -r '.unchanged_sensor_inputs[]|.sha256+"  "+.path' "$owner/$manifest" | sha256sum -c --strict --quiet -)
cp "$profile/SHA256SUMS" "$stage/parent-profile.sha256"
cp "$boot/lock.json" "$stage/parent-boot-lock.json"
(cd "$boot"; find . -type f ! -name lock.json -print0 | sort -z | xargs -0 sha256sum) > "$stage/parent-boot.sha256"
jq -r '.imports[].path' "$owner/$manifest" > "$stage/overlays"
while read -r relative; do
    [[ $relative =~ ^(src|tests)/[a-zA-Z0-9_,./-]+$ && $relative != *..* ]]
    install -Dm644 "$owner/$relative" "$profile/$relative"
    install -Dm644 "$owner/$relative" "$boot/$relative"
done < "$stage/overlays"
# Only the ABI-specific ALSA identity changes; policy and electrical values stay exact.
audio_path=src/audio/uke-audio-card.c
audio_release="7.3.1-${revision}u"
audio_driver=uke${audio_release//./_}
[[ ${#audio_driver} -lt 16 ]]
for tree in "$profile" "$boot"; do
    [[ $(grep -Fo 'uke7.3.1-11003u' "$tree/$audio_path" | wc -l) == 2 ]]
    sed "s/uke7[.]3[.]1-11003u/uke$audio_release/g" "$tree/$audio_path" > "$stage/audio-card.c"
    install -m644 "$stage/audio-card.c" "$tree/$audio_path"
done
printf '%s\n' "$audio_path" >> "$stage/overlays"
while read -r relative; do
    digest=$(sha256sum "$boot/$relative"); digest=${digest%% *}
    jq --arg path "$relative" --arg digest "$digest" \
        'if any(.source_assets[];.path==$path) then
          (.source_assets[]|select(.path==$path)|.sha256)=$digest
         else .source_assets += [{path:$path,sha256:$digest}] end' \
        "$boot/lock.json" > "$stage/lock.json"
    install -m644 "$stage/lock.json" "$boot/lock.json"
done < "$stage/overlays"
bash "$profile/src/audio/desktop/install-policy.sh" "$stage/audio-policy-probe" "7.3.1-$revision-unstable"
[[ -d $stage/audio-policy-probe/usr/share/alsa/ucm2/Qualcomm/$audio_driver ]]
[[ -r $stage/audio-policy-probe/usr/share/alsa/ucm2/conf.d/$audio_driver/POCO-Pad-X1.conf ]]
for role in profile boot; do
    tree=$profile receipt=$stage/parent-profile.sha256
    [[ $role != boot ]] || { tree=$boot; receipt=$stage/parent-boot.sha256; }
    while read -r expected relative; do
        relative=${relative#./}
        if [[ $role == profile && ( $relative == source-commit || $relative == source-composition.json ) ]]; then continue; fi
        if ! grep -Fxq "$relative" "$stage/overlays"; then
            printf '%s  %s\n' "$expected" "$tree/$relative" | sha256sum -c --strict --quiet -
        fi
    done < "$receipt"
done
cmp <(jq -S 'del(.source_assets)' "$stage/parent-boot-lock.json") \
    <(jq -S 'del(.source_assets)' "$boot/lock.json")
jq -e --slurpfile old "$stage/parent-boot-lock.json" --rawfile overlays "$stage/overlays" '
 ($overlays|split("\n")|map(select(length>0))) as $allowed |
 [.source_assets[].path] as $paths |
 all($old[0].source_assets[]; .path as $p | $paths|index($p)!=null) and
 all(.source_assets[]; .path as $p |
   any($old[0].source_assets[];.path==$p) or ($allowed|index($p)!=null)) and
 ((.source_assets|map(.path)|length)==(.source_assets|map(.path)|unique|length))' \
    "$boot/lock.json" >/dev/null
history=source-composition-before-ssc-observation.json
test ! -e "$profile/$history"
cp "$profile/source-composition.json" "$profile/$history"
install -Dm644 "$owner/$manifest" "$profile/$manifest"
install -Dm644 "$owner/manifests/ssc-observation-source-20261104.json" \
    "$profile/manifests/ssc-observation-source-20261104.json"
commit=$(git -C "$owner" rev-parse HEAD)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq -Rn '[inputs]' < "$stage/overlays" > "$stage/overlays.json"
jq --arg commit "$commit" --arg revision "$revision" --arg hash "$parent_hash" --arg audio "$audio_driver" \
    --arg history "$history" --slurpfile overlays "$stage/overlays.json" '
 . + {source_commit:$commit,kernel_release:("7.3.1-"+$revision+"-unstable"),rpm_revision:$revision,
 source_mode:"qualified11003-with-read-only-ssc-discovery-observations",
 parent_copr_build:11260288,parent_srpm_sha256:$hash,parent_composition:$history,
 parent_source_commit:"261d85e218906f78d37810db78a4aa80cd900067",
 diagnostic_audio_driver:$audio,overlays:$overlays[0],kernel_driver_source_unchanged:false,
 ssc_observation_abi:1,qualified_ssc_observation_check:11260554,
 qualified_ssc_observation_source:"afe3b4171cb552775d92561451db877bbb3732de",
 ssc_observation_source_manifest:"manifests/ssc-observation-cohort-20261104.json",
 ssc_observation_read_issues_qmi:false,ssc_observation_private_data:false,
 automatic_policy_unchanged:true,automatic_seamless_staging_required:true,
 package_rollback_default:"enforced",preserve_local_rollback_preference:true,
 package_family:"senemos-uke-linux-kernel-mainline-unstable",kernel_abi_suffix:"-unstable",
 normal_kernel_promotion:false,device_installation:false,physical_acceptance:false}' \
    "$profile/$history" > "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --strict --quiet -)
install -m644 "$boot/lock.json" "$output/boot-payload.json"
for tree in native-profile boot-recipe; do
    archive=$native_archive
    [[ $tree != boot-recipe ]] || archive=$boot_archive
    tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
        -cJf "$output/$archive" -C "$stage/unpacked" "$tree"
done
# Keep every existing check. Exercise actual callbacks before the full Image build.
awk -v revision="$revision" '
 /^%global senemos_build_release 11003$/ {$0="%global senemos_build_release "revision;release++}
 /^Name:/ {print;print "Requires: uke-kernel-update >= 1.8.90";dependency++;next}
 /^%build$/ {
  print
  print "cmp native-profile/src/sensors/uke-ssc-iio.c drivers/iio/common/uke-ssc/uke-ssc-iio.c"
  print "bash native-profile/tests/ssc-native-contract.sh \"$PWD\""
  build++;next
 }
 /^%check$/ {
  print
  print "cmp native-profile/src/sensors/uke-ssc-iio.c drivers/iio/common/uke-ssc/uke-ssc-iio.c"
  print "cmp native-profile/src/sensors/sysfs-driver-uke-ssc Documentation/ABI/testing/sysfs-driver-uke-ssc"
  print "llvm-nm %{_uke_out}/drivers/iio/common/uke-ssc/uke-ssc-iio.o > native-generated/ssc-observation-symbols.txt"
  print "for field in service_count lookup_fault suspended client_connected declared_sensors discovered_sensors ready_sensors registered_sensors last_error last_error_stage; do"
  print " grep -Eq \"[[:space:]]ssc_${field}_show$\" native-generated/ssc-observation-symbols.txt"
  print "done"
  check++;next
 }
 /^%changelog$/ {
  print;print "* Wed Nov 04 2026 Uke contributors - 7.3.1-"revision
  print "- Preserve the qualified 11003 camera, NFC, networking, color and power sources."
  print "- Expose read-only SSC discovery counts and generation-scoped failure stages."
  print "- Retain seamless staging and the persistent local rollback preference."
  print "";next
 }
 {print}
 END {if(release!=1 || dependency!=1 || build!=1 || check!=1)exit 1}
' "$spec" > "$stage/next.spec"
install -m644 "$stage/next.spec" "$spec"
sha256sum -c --strict --quiet "$stage/retained-sources.sha256"
bash "$owner/tests/unstable-boot-family731-contract.sh" "$spec"
[[ $(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec") == 7.3.1-$revision ]]
printf 'Qualified11003 retained with read-only SSC observations; full kernel and physical sensor acceptance pending\n'
