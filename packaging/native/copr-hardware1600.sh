#!/usr/bin/env bash
# COPR only: retain release 1500 and combine qualified SSC temperature and NFC/IR.
set -Eeuo pipefail
trap 'status=$?; printf "SSC source preparation failed at line %s (exit %s)\n" "$LINENO" "$status" >&2; exit "$status"' ERR
export LC_ALL=C
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?COPR result directory}")
# Keep the dependent candidate queued remotely until its retained parent passes.
for attempt in {1..60}; do
    parent_state=$(curl -fsSL --max-time 45 https://copr.fedorainfracloud.org/api_3/build/11251503 | jq -er .state)
    case $parent_state in
        succeeded) break;;
        running|pending|starting|importing|waiting)
            printf 'Waiting for retained parent build 11251503: %s\n' "$parent_state"
            sleep 30;;
        *) printf 'Retained parent build did not pass: %s\n' "$parent_state" >&2; exit 1;;
    esac
done
[[ $parent_state == succeeded ]]
for checked in 11251492 11251535; do
    [[ $(curl -fsSL --max-time 45 "https://copr.fedorainfracloud.org/api_3/build/$checked" | jq -er .state) == succeeded ]]
done
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline 7.3.1-1600
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
curl -fLsS --retry 2 --proto '=https' --proto-redir '=https' \
 https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/11251503/senemos-uke-linux-kernel-mainline-7.3.1-1500.src.rpm -o "$stage/base.src.rpm"
parent_hash=$(sha256sum "$stage/base.src.rpm"); parent_hash=${parent_hash%% *}
# Pin both RPM content digests; verify the complete downloaded RPM.
[[ $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$stage/base.src.rpm") == senemos-uke-linux-kernel-mainline-7.3.1-1500 ]]
[[ $(rpm -qp --qf '%{SHA256HEADER}' "$stage/base.src.rpm") == abea001cf467330fc360543023fcb8a9fa9726a08c53fd8e966c2683a3a51478 ]]
[[ $(rpm -qp --qf '%{PAYLOADSHA256}' "$stage/base.src.rpm") == 60f5a60e762725b9222dce4f6e61d5e1158adde6bf51c604ebed639946c87afc ]]
rpmkeys --checksig --nosignature --verbose "$stage/base.src.rpm"
rpm2cpio "$stage/base.src.rpm" > "$stage/base.cpio"
cpio -t --quiet < "$stage/base.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/base.cpio")
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
[[ $(cat "$profile/source-commit") == 3d8702b0116c4388d3977e8f566bcca900f2d3f6 ]]
jq -e '.kernel_release=="7.3.1-1500" and .native_ssc_iio_abi==1 and .binder_ipc_builtin and .binderfs_builtin and
 .touch_recovery_attempts_per_powered_epoch==1 and .native_memlat_groups==["llcc","l3"] and
 .panel_variants==["o82_36_02_0a","o82_42_02_0b"] and .touch_variants==["tianma","csot"]' \
 "$profile/source-composition.json" >/dev/null
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS)
cp "$profile/SHA256SUMS" "$stage/parent-profile.sha256"
cp "$boot/lock.json" "$stage/parent-boot-lock.json"
cmp "$profile/native.config" "$boot/packaging/native/native.config"
cmp "$boot/lock.json" "$output/boot-payload.json"
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --quiet -)
# Preserve SSC/Binder and merge only the reviewed standard IR encoder settings.
awk '
 FNR==NR {if(/^CONFIG_/) {split($0,a,"="); setting[a[1]]=$0} next}
 {key=$0; sub(/^# /,"",key); sub(/[= ].*$/,"",key)
  if(key in setting) {print setting[key]; delete setting[key]} else print}
 END {for(key in setting) print setting[key]}
' "$owner/configs/nfc-ir.config" "$profile/native.config" > "$stage/native.config"
install -m644 "$stage/native.config" "$profile/native.config"
grep -Fx CONFIG_IIO_UKE_SSC=m "$profile/native.config"
grep -Fx CONFIG_ANDROID_BINDER_IPC=y "$profile/native.config"
install -m644 "$profile/native.config" "$boot/packaging/native/native.config"
printf 'native.config\n' > "$stage/overlays"
cat "$owner/packaging/native/hardware1500-overlays.txt" >> "$stage/overlays"
printf 'packaging/native/native.config\n' > "$stage/boot-overlays"
config_hash=$(sha256sum "$profile/native.config"); config_hash=${config_hash%% *}
jq --arg hash "$config_hash" '(.source_assets[]|select(.path=="packaging/native/native.config")|.sha256)=$hash' \
 "$boot/lock.json" > "$stage/lock.json"
install -m644 "$stage/lock.json" "$boot/lock.json"
while read -r relative; do
    [[ $relative =~ ^(src|tests|configs)/[a-zA-Z0-9_,./-]+$ && $relative != *..* ]]
    install -Dm644 "$owner/$relative" "$profile/$relative"
    case $relative in
        src/nfc/fm19511-uapi.h|src/infrared/ir-spi-uke.c)
            jq -e --arg path "$relative" '[.source_assets[]|select(.path==$path)]|length==0' "$boot/lock.json" >/dev/null
            hash=$(sha256sum "$owner/$relative"); hash=${hash%% *}
            jq --arg path "$relative" --arg hash "$hash" '.source_assets += [{path:$path,sha256:$hash}]' \
                "$boot/lock.json" > "$stage/lock.json"
            install -m644 "$stage/lock.json" "$boot/lock.json";;
    esac
    if jq -e --arg path "$relative" '.source_assets[]|select(.path==$path)' "$boot/lock.json" >/dev/null; then
        install -Dm644 "$owner/$relative" "$boot/$relative"
        printf '%s\n' "$relative" >> "$stage/boot-overlays"
        hash=$(sha256sum "$boot/$relative"); hash=${hash%% *}
        jq --arg path "$relative" --arg hash "$hash" \
            '(.source_assets[]|select(.path==$path)|.sha256)=$hash' \
            "$boot/lock.json" > "$stage/lock.json"
        install -m644 "$stage/lock.json" "$boot/lock.json"
    fi
done < "$owner/packaging/native/hardware1500-overlays.txt"
while read -r expected relative; do
    relative=${relative#./}
    case $relative in source-commit|source-composition.json) continue;; esac
    if ! grep -Fxq -- "$relative" "$stage/overlays"; then
        printf '%s  %s\n' "$expected" "$profile/$relative" | sha256sum -c --quiet -
    fi
done < "$stage/parent-profile.sha256"
cmp <(jq -S 'del(.source_assets[].sha256)' "$stage/parent-boot-lock.json") \
    <(jq -S '.source_assets |= map(select(.path!="src/nfc/fm19511-uapi.h" and .path!="src/infrared/ir-spi-uke.c")) | del(.source_assets[].sha256)' "$boot/lock.json")
while IFS=$'\t' read -r relative expected; do
    if ! grep -Fxq "$relative" "$stage/boot-overlays"; then
        printf '%s  %s\n' "$expected" "$boot/$relative" | sha256sum -c --quiet -
    fi
done < <(jq -r '.source_assets[]|[.path,.sha256]|@tsv' "$stage/parent-boot-lock.json")
cp "$profile/source-composition.json" "$profile/source-composition-before1600.json"
commit=$(git -C "$owner" rev-parse HEAD)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq -Rn '[inputs]' < "$stage/overlays" > "$stage/overlays.json"
jq --arg commit "$commit" --arg parent_hash "$parent_hash" --slurpfile overlays "$stage/overlays.json" '. + {
 source_commit:$commit,source_mode:"retained1500-with-ssc-temperature-and-native-nfc-ir-v2",
 parent_copr_build:11251503,parent_srpm_sha256:$parent_hash,
 parent_source_commit:"3d8702b0116c4388d3977e8f566bcca900f2d3f6",
 parent_header_sha256:"abea001cf467330fc360543023fcb8a9fa9726a08c53fd8e966c2683a3a51478",
 parent_payload_sha256:"60f5a60e762725b9222dce4f6e61d5e1158adde6bf51c604ebed639946c87afc",
 parent_composition:"source-composition-before1600.json",kernel_release:"7.3.1-1600",rpm_revision:"1600",
 overlays:$overlays[0],kernel_driver_source_unchanged:false,
 native_ssc_iio_abi:1,ssc_service:400,ssc_service_version:1,ssc_service_instance:0,
 ssc_supported_datatypes:["accel","gyro","mag","ambient_light","ambient_light_back","proximity","sar","sensor_temperature"],
 ssc_unqualified_datatypes:["cct_front","flicker"],ssc_timestamp_source:"host-receipt",
 ssc_mount_matrix_inferred:false,ssc_temperature_unit:"millicelsius",
 nfc_role:"type2-tag",nfc_reader:false,nfc_eeprom_write:false,nfc_atomic_memory_read:true,
 nfc_raw_irq_status:true,nfc_system_wakeup:true,ir_role:"transmitter",ir_receive:false,ir_explicit_word_bits:16,
 qualified_nfc_ir_build:11251492,qualified_temperature_check:11251535,
 changed_kernel_files:["drivers/iio/common/uke-ssc/uke-ssc-iio.c","arch/arm64/kernel/uke-hardware.h",
 "drivers/misc/fm19511-uke.c","drivers/misc/fm19511-uapi.h","include/uapi/linux/fm19511.h","drivers/media/rc/ir-spi.c"],firmware_payload_included:false,physical_acceptance:false
 }' "$profile/source-composition-before1600.json" > "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --quiet -)
for tree in native-profile boot-recipe; do
    archive=$native_archive
    [[ $tree != boot-recipe ]] || archive=$boot_archive
    tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner -cJf "$output/$archive" -C "$stage/unpacked" "$tree"
done
install -m644 "$boot/lock.json" "$output/boot-payload.json"
[[ $(grep -Fxc '%global senemos_build_release 1500' "$spec") == 1 ]]
[[ $(grep -Fxc 'Provides: uke-kernel(ssc-iio-v1) = 1' "$spec") == 1 ]]
[[ $(grep -Fxc '%check' "$spec") == 1 ]]
[[ $(grep -Fxc 'uke_build_start=$SECONDS' "$spec") == 1 ]]
awk '
 /^%global senemos_build_release 1500$/ {$0="%global senemos_build_release 1600"}
 /^Provides: uke-kernel\(ssc-iio-v1\) = 1$/ {
  print;print "Provides: uke-kernel(nfc-ir-v2) = 1";next
 }
 /^uke_build_start=\$SECONDS$/ {
  print
  print "CC=clang CFLAGS=\"\" bash native-profile/tests/fm19511-contract.sh"
  print "CC=clang CFLAGS=\"\" bash native-profile/tests/fm19511-pm-contract.sh"
  print "CC=clang CFLAGS=\"\" bash native-profile/tests/ir-spi-contract.sh drivers/media/rc/ir-spi.c"
  print "cmp native-profile/src/nfc/fm19511-uapi.h include/uapi/linux/fm19511.h"
  next
 }
 /^%check$/ {
  print;print "bash native-profile/tests/nfc-ir-v2-package-contract.sh %{_uke_out}";next
 }
 /^%changelog$/ {
  print
  print "* Tue Nov 03 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-1600"
  print "- Combine native SSC sensor temperature with qualified NFC tag and IR updates."
  print "- Preserve the millicelsius ABI, tag events and read-only memory access."
  print "- Retain supplier variants, MEMLAT, touch recovery and Binder support."
  print "";next
 }
 {print}
' "$spec" > "$stage/next.spec"
install -m644 "$stage/next.spec" "$spec"
sha256sum -c "$stage/retained-sources.sha256"
[[ $(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec") == 7.3.1-1600 ]]
