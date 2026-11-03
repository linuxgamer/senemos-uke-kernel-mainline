#!/usr/bin/env bash
# COPR only: retain1900 and select the documented SSC large-report route.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?Pass the remote source result directory}")
for attempt in {1..60}; do
    parent_state=$(curl -fsSL --max-time 45 https://copr.fedorainfracloud.org/api_3/build/11252138 | jq -er .state)
    case $parent_state in
        succeeded) break;;
        running|pending|starting|importing|waiting)
            printf 'Waiting for retained parent1900: %s\n' "$parent_state"; sleep 30;;
        *) printf 'Retained parent did not pass: %s\n' "$parent_state" >&2; exit 1;;
    esac
done
[[ $parent_state == succeeded ]]
[[ $(curl -fsSL --max-time 45 https://copr.fedorainfracloud.org/api_3/build/11252237 | jq -er .state) == succeeded ]]
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline 7.3.1-1910
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
curl -fLsS --retry 2 --proto '=https' --proto-redir '=https' \
    https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/11252138/senemos-uke-linux-kernel-mainline-7.3.1-1900.src.rpm \
    -o "$stage/parent.src.rpm"
[[ $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$stage/parent.src.rpm") == senemos-uke-linux-kernel-mainline-7.3.1-1900 ]]
[[ $(rpm -qp --qf '%{SHA256HEADER}' "$stage/parent.src.rpm") == 1bb1e6fab32581f77f6babb69e2be7d405dfdf6a6d1513d515994d551e931f89 ]]
[[ $(rpm -qp --qf '%{PAYLOADSHA256}' "$stage/parent.src.rpm") == c91b0a390f73a7063bcb49221cf94d42ef2242b95e3a26f2d84b4428e7ca207f ]]
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
[[ $(cat "$profile/source-commit") == aec8163b1ba0fba34e94f99accc99a18a46f8810 ]]
jq -e '.kernel_release=="7.3.1-1900" and .ssc_adsp_supplier_bound_gate==1 and
 .o82_regdma_resource=={start:"0x0af80000",size:"0x7000"} and
 .qualified_o82_kms_check==11252062 and (.o82_color_dma_enabled|not) and (.native_hdr_advertised|not) and
 .native_ssc_iio_abi==1 and .ssc_temperature_unit=="millicelsius" and
 .nfc_atomic_memory_read and .nfc_system_wakeup and .ir_explicit_word_bits==16 and
 .rtc_backend=="qseecom-uefisecapp-RTCInfo" and .binder_ipc_builtin and .binderfs_builtin and
 .memlat_l3_capacity=="ERANGE-only-descending-OEM-map" and .memlat_strict_provider_unchanged and
 .touch_recovery_attempts_per_powered_epoch==1 and
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
src/sensors/uke-ssc-protocol.c
tests/ssc-native-contract.c
FILES
: > "$stage/boot-overlays"
while read -r relative; do
    [[ $relative =~ ^(src|tests)/[a-zA-Z0-9_,./-]+$ && $relative != *..* ]]
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
cp "$profile/source-composition.json" "$profile/source-composition-before1910.json"
commit=$(git -C "$owner" rev-parse HEAD)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq -Rn '[inputs]' < "$stage/overlays" > "$stage/overlays.json"
jq --arg commit "$commit" --arg parent_hash "$parent_hash" --slurpfile overlays "$stage/overlays.json" '. + {
 source_commit:$commit,source_mode:"retained1900-with-explicit-ssc-large-reports",
 parent_copr_build:11252138,parent_srpm_sha256:$parent_hash,
 parent_source_commit:"aec8163b1ba0fba34e94f99accc99a18a46f8810",
 parent_header_sha256:"1bb1e6fab32581f77f6babb69e2be7d405dfdf6a6d1513d515994d551e931f89",
 parent_payload_sha256:"c91b0a390f73a7063bcb49221cf94d42ef2242b95e3a26f2d84b4428e7ca207f",
 parent_composition:"source-composition-before1910.json",kernel_release:"7.3.1-1910",rpm_revision:"1910",
 overlays:$overlays[0],kernel_driver_source_unchanged:false,
 qualified_ssc_large_report_check:11252237,ssc_report_type:1,ssc_indication_ids:[33,34],
 ssc_payload_limit:16384,ssc_native_publication_accepted:false,physical_acceptance:false,
 changed_kernel_files:["drivers/iio/common/uke-ssc/uke-ssc-iio.c",
 "drivers/iio/common/uke-ssc/uke-ssc-protocol.c"]
 }' "$profile/source-composition-before1910.json" > "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --quiet -)
for tree in native-profile boot-recipe; do
    archive=$native_archive
    [[ $tree != boot-recipe ]] || archive=$boot_archive
    tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
        -cJf "$output/$archive" -C "$stage/unpacked" "$tree"
done
install -m644 "$boot/lock.json" "$output/boot-payload.json"
[[ $(grep -Fxc '%global senemos_build_release 1900' "$spec") == 1 && $(grep -Fxc 'uke_build_start=$SECONDS' "$spec") == 1 ]]
awk '
 /^%global senemos_build_release 1900$/ {$0="%global senemos_build_release 1910"}
 /^uke_build_start=\$SECONDS$/ {
  print
  print "cmp native-profile/src/sensors/uke-ssc-iio.c drivers/iio/common/uke-ssc/uke-ssc-iio.c"
  print "cmp native-profile/src/sensors/uke-ssc-protocol.c drivers/iio/common/uke-ssc/uke-ssc-protocol.c"
  next
 }
 /^%changelog$/ {
  print;print "* Wed Nov 04 2026 Uke contributors - 7.3.1-1910"
  print "- Explicitly select large SSC reports and accept both documented report IDs."
  print "- Retain strict framing, the bound ADSP supplier and the complete1900 cohort."
  print "- Check complete QMI discovery, metadata, samples and maximum payloads."
  print "";next
 }
 {print}
' "$spec" > "$stage/next.spec"
install -m644 "$stage/next.spec" "$spec"
sha256sum -c "$stage/retained-sources.sha256"
[[ $(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec") == 7.3.1-1910 ]]
