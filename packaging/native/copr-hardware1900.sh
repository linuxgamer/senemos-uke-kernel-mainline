#!/usr/bin/env bash
# COPR only: retain 1800 and add checked SSC supplier and DPU resource hooks.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?Pass the remote source result directory}")
for attempt in {1..60}; do
    parent_state=$(curl -fsSL --max-time 45 https://copr.fedorainfracloud.org/api_3/build/11251976 | jq -er .state)
    case $parent_state in
        succeeded) break;;
        running|pending|starting|importing|waiting)
            printf 'Waiting for retained parent1800: %s\n' "$parent_state"; sleep 30;;
        *) printf 'Retained parent did not pass: %s\n' "$parent_state" >&2; exit 1;;
    esac
done
[[ $parent_state == succeeded ]]
for checked in 11251980 11252062; do
    [[ $(curl -fsSL --max-time 45 "https://copr.fedorainfracloud.org/api_3/build/$checked" | jq -er .state) == succeeded ]]
done
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline 7.3.1-1900
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
curl -fLsS --retry 2 --proto '=https' --proto-redir '=https' \
    https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/11251976/senemos-uke-linux-kernel-mainline-7.3.1-1800.src.rpm \
    -o "$stage/parent.src.rpm"
[[ $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$stage/parent.src.rpm") == senemos-uke-linux-kernel-mainline-7.3.1-1800 ]]
[[ $(rpm -qp --qf '%{SHA256HEADER}' "$stage/parent.src.rpm") == 4f8afaa99c599623d406f92dec5607f751701f7f29c9f97ff7d0e6636115016c ]]
[[ $(rpm -qp --qf '%{PAYLOADSHA256}' "$stage/parent.src.rpm") == 6bb2dcb4f01804fb0dc96cdc875fc404e27bb0e941aefd0fc215065994400cae ]]
rpmkeys --checksig --nosignature --verbose "$stage/parent.src.rpm"
parent_hash=$(sha256sum "$stage/parent.src.rpm"); parent_hash=${parent_hash%% *}
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
    tar -tJf "$output/$archive" > "$stage/archive.entries"
    awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/archive.entries"
    tar -xJf "$output/$archive" -C "$stage/unpacked"
done
profile=$stage/unpacked/native-profile
boot=$stage/unpacked/boot-recipe
[[ $(cat "$profile/source-commit") == cfc3d3958e20be89bb741b41f135301dacaf6b97 ]]
jq -e '.kernel_release=="7.3.1-1800" and .native_ssc_iio_abi==1 and
 .ssc_temperature_unit=="millicelsius" and .nfc_atomic_memory_read and .nfc_system_wakeup and
 .ir_explicit_word_bits==16 and .rtc_backend=="qseecom-uefisecapp-RTCInfo" and
 .memlat_l3_capacity=="ERANGE-only-descending-OEM-map" and .memlat_strict_provider_unchanged and
 .binder_ipc_builtin and .binderfs_builtin and .touch_recovery_attempts_per_powered_epoch==1 and
 .panel_variants==["o82_36_02_0a","o82_42_02_0b"] and .touch_variants==["tianma","csot"]' \
    "$profile/source-composition.json" >/dev/null
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --quiet -)
cmp "$profile/native.config" "$boot/packaging/native/native.config"
cmp "$boot/lock.json" "$output/boot-payload.json"
cp "$profile/SHA256SUMS" "$stage/parent-profile.sha256"
cp "$boot/lock.json" "$stage/parent-boot-lock.json"
(cd "$boot"; find . -type f ! -name lock.json -print0 | sort -z | xargs -0 sha256sum) > "$stage/parent-boot.sha256"
cat > "$stage/overlays" <<'FILES'
src/sensors/uke-ssc-iio.c
tests/ssc-supplier-contract.sh
src/display/dpu_o82_platform.c
src/display/dpu_o82_platform.h
src/display/dpu_o82_regdma.c
src/display/dpu_o82_regdma.h
src/display/o82-regdma.h
src/display/prepare-o82-regdma.sh
src/display/bindings/qcom,sm7675-dpu.yaml
src/display/sm7675-uke-native-display.dtso
patches/display/0072-o82-regdma-resource.patch
tests/o82-platform-contract.sh
tests/hardware1900-package-contract.sh
FILES
: > "$stage/boot-overlays"
while read -r relative; do
    [[ $relative =~ ^(src|tests|patches)/[a-zA-Z0-9_,./-]+$ && $relative != *..* ]]
    install -Dm644 "$owner/$relative" "$profile/$relative"
    if jq -e --arg path "$relative" '.source_assets[]|select(.path==$path)' "$boot/lock.json" >/dev/null; then
        install -Dm644 "$owner/$relative" "$boot/$relative"
        printf '%s\n' "$relative" >> "$stage/boot-overlays"
        digest=$(sha256sum "$boot/$relative"); digest=${digest%% *}
        jq --arg path "$relative" --arg digest "$digest" \
            '(.source_assets[]|select(.path==$path)|.sha256)=$digest' \
            "$boot/lock.json" > "$stage/lock.json"
        install -m644 "$stage/lock.json" "$boot/lock.json"
    fi
done < "$stage/overlays"
# Extend, rather than replace, the complete retained preparation and its checks.
cat >> "$profile/prepare.sh" <<'PREPARE'

# Explicit1900 extension follows all historical KMS source receipts.
bash "$profile/src/display/prepare-o82-regdma.sh" "$kernel"
bash "$profile/tests/o82-platform-contract.sh"
bash "$profile/tests/ssc-supplier-contract.sh"
sha256sum "$profile/patches/display/0072-o82-regdma-resource.patch" \
    "$profile/src/display/dpu_o82_platform.c" >> "$output/abl-source-SHA256SUMS"
PREPARE
printf 'prepare.sh\n' >> "$stage/overlays"
while read -r expected relative; do
    relative=${relative#./}
    case $relative in source-commit|source-composition.json) continue;; esac
    if ! grep -Fxq "$relative" "$stage/overlays"; then
        printf '%s  %s\n' "$expected" "$profile/$relative" | sha256sum -c --quiet -
    fi
done < "$stage/parent-profile.sha256"
while read -r expected relative; do
    relative=${relative#./}
    if ! grep -Fxq "$relative" "$stage/boot-overlays"; then
        printf '%s  %s\n' "$expected" "$boot/$relative" | sha256sum -c --quiet -
    fi
done < "$stage/parent-boot.sha256"
cmp <(jq -S 'del(.source_assets[].sha256)' "$stage/parent-boot-lock.json") \
    <(jq -S 'del(.source_assets[].sha256)' "$boot/lock.json")
cp "$profile/source-composition.json" "$profile/source-composition-before1900.json"
commit=$(git -C "$owner" rev-parse HEAD)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq -Rn '[inputs]' < "$stage/overlays" > "$stage/overlays.json"
jq --arg commit "$commit" --arg parent_hash "$parent_hash" --slurpfile overlays "$stage/overlays.json" '. + {
 source_commit:$commit,source_mode:"retained1800-with-ssc-supplier-and-regdma-resource",
 parent_copr_build:11251976,parent_srpm_sha256:$parent_hash,
 parent_source_commit:"cfc3d3958e20be89bb741b41f135301dacaf6b97",
 parent_header_sha256:"4f8afaa99c599623d406f92dec5607f751701f7f29c9f97ff7d0e6636115016c",
 parent_payload_sha256:"6bb2dcb4f01804fb0dc96cdc875fc404e27bb0e941aefd0fc215065994400cae",
 parent_composition:"source-composition-before1900.json",kernel_release:"7.3.1-1900",rpm_revision:"1900",
 overlays:$overlays[0],kernel_driver_source_unchanged:false,
 ssc_adsp_supplier_bound_gate:1,qualified_ssc_supplier_check:11251980,
 o82_regdma_resource:{start:"0x0af80000",size:"0x7000"},qualified_o82_kms_check:11252062,
 o82_color_dma_enabled:false,native_hdr_advertised:false,physical_acceptance:false,
 changed_kernel_files:["drivers/iio/common/uke-ssc/uke-ssc-iio.c",
 "drivers/gpu/drm/msm/disp/dpu1/dpu_kms.c","drivers/gpu/drm/msm/disp/dpu1/dpu_kms.h",
 "drivers/gpu/drm/msm/Makefile","drivers/gpu/drm/msm/disp/dpu1/dpu_o82_platform.c",
 "drivers/gpu/drm/msm/disp/dpu1/dpu_o82_platform.h",
 "drivers/gpu/drm/msm/disp/dpu1/dpu_o82_regdma.c",
 "drivers/gpu/drm/msm/disp/dpu1/dpu_o82_regdma.h","drivers/gpu/drm/msm/disp/dpu1/o82-regdma.h",
 "Documentation/devicetree/bindings/display/msm/qcom,sm7675-dpu.yaml",
 "arch/arm64/kernel/uke-native-display.h"]
 }' "$profile/source-composition-before1900.json" > "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --quiet -)
for tree in native-profile boot-recipe; do
    archive=$native_archive
    [[ $tree != boot-recipe ]] || archive=$boot_archive
    tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
        -cJf "$output/$archive" -C "$stage/unpacked" "$tree"
done
install -m644 "$boot/lock.json" "$output/boot-payload.json"
[[ $(grep -Fxc '%global senemos_build_release 1800' "$spec") == 1 && $(grep -Fxc '%check' "$spec") == 1 ]]
awk '
 /^%global senemos_build_release 1800$/ {$0="%global senemos_build_release 1900"}
 /^%check$/ {print;print "bash native-profile/tests/hardware1900-package-contract.sh \"$PWD\" %{_uke_out}";next}
 /^%changelog$/ {
  print;print "* Wed Nov 04 2026 Uke contributors - 7.3.1-1900"
  print "- Retain adaptive L3 capacity, secure RTC, SSC temperature and NFC infrared."
  print "- Gate SSC on the bound ADSP supplier and link separate DPU REGDMA resources."
  print "- Verify the resulting modules and both supplier DT resource tuples."
  print "";next
 }
 {print}
' "$spec" > "$stage/next.spec"
install -m644 "$stage/next.spec" "$spec"
sha256sum -c "$stage/retained-sources.sha256"
[[ $(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec") == 7.3.1-1900 ]]
