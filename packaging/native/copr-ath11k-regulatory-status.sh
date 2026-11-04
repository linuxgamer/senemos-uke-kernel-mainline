#!/usr/bin/env bash
# COPR only: retain the qualified 2700 cohort and repair ath11k diagnostics.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?Remote source result directory}")
revision=${2:?Fresh revision without the Fedora suffix}
[[ $revision =~ ^[1-9][0-9]{3,5}$ ]]
release=7.3.1-$revision
[[ $(curl -fsS --max-time 45 https://copr.fedorainfracloud.org/api_3/build/11252415 | jq -er .state) == succeeded ]]
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline "$release"
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
curl -fLsS --retry 2 --proto '=https' --proto-redir '=https' \
 https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/11252415/senemos-uke-linux-kernel-mainline-7.3.1-2700.src.rpm \
 -o "$stage/parent.src.rpm"
[[ $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$stage/parent.src.rpm") == senemos-uke-linux-kernel-mainline-7.3.1-2700 ]]
[[ $(rpm -qp --qf '%{SHA256HEADER}' "$stage/parent.src.rpm") == f4ea588bdf730995c63fea28dd9a1dc2b6b7508faa778a0b1017a4a205e83cd2 ]]
[[ $(rpm -qp --qf '%{PAYLOADSHA256}' "$stage/parent.src.rpm") == 0b2d7e79fd78fc95ea2c54b2b22aaf063a342891d0a9fd4131ee423bbeccfb89 ]]
rpmkeys --checksig --nosignature --verbose "$stage/parent.src.rpm"
parent_hash=$(sha256sum "$stage/parent.src.rpm"); parent_hash=${parent_hash%% *}
printf 'Verified complete parent2700 SRPM SHA-256: %s\n' "$parent_hash"
rpm2cpio "$stage/parent.src.rpm" > "$stage/parent.cpio"
cpio -t --quiet < "$stage/parent.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/parent.cpio")
spec=$output/senemos-uke-linux-kernel-mainline.spec
archive=senemos-native-profile-7.3.1.tar.xz
boot_archive=senemos-uke-boot-recipe.tar.xz
find "$output" -maxdepth 1 -type f ! -name "${spec##*/}" ! -name "$archive" \
 -print0 | sort -z | xargs -0 sha256sum > "$stage/retained-sources.sha256"
for file in "$archive" "$boot_archive"; do
 tar -tJf "$output/$file" > "$stage/archive.entries"
 awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/archive.entries"
done
tar -xJf "$output/$archive" -C "$stage/unpacked"
profile=$stage/unpacked/native-profile
[[ $(cat "$profile/source-commit") == c0de80bf9f7f5ac18b4fb5ceb623342f285382ee ]]
jq -e '.kernel_release=="7.3.1-2700" and .wcd939x_telemetry_readonly==1 and
 .wcd939x_telemetry_getters_unchanged and .wcd939x_electrical_settings_unchanged and
 .ssc_adsp_supplier_bound_gate==1 and .qualified_ssc_large_report_check==11252237 and
 .ssc_report_type==1 and .ssc_indication_ids==[33,34] and .ssc_payload_limit==16384 and
 .o82_regdma_resource=={start:"0x0af80000",size:"0x7000"} and
 (.o82_color_dma_enabled|not) and (.native_hdr_advertised|not) and
 .native_ssc_iio_abi==1 and .ssc_temperature_unit=="millicelsius" and
 .nfc_atomic_memory_read and .nfc_system_wakeup and .ir_explicit_word_bits==16 and
 .rtc_backend=="qseecom-uefisecapp-RTCInfo" and .binder_ipc_builtin and .binderfs_builtin and
 .memlat_l3_capacity=="ERANGE-only-descending-OEM-map" and .memlat_strict_provider_unchanged and
 .native_config_digest_scope=="native-profile/native.config" and
 .touch_recovery_attempts_per_powered_epoch==1 and
 .panel_variants==["o82_36_02_0a","o82_42_02_0b"] and .touch_variants==["tianma","csot"]' \
 "$profile/source-composition.json" >/dev/null
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS)
tar -xOJf "$output/$boot_archive" boot-recipe/packaging/native/native.config > "$stage/boot.config"
tar -xOJf "$output/$boot_archive" boot-recipe/lock.json > "$stage/boot-lock.json"
cmp "$profile/native.config" "$stage/boot.config"
cmp "$stage/boot-lock.json" "$output/boot-payload.json"
config_hash=$(sha256sum "$profile/native.config"); config_hash=${config_hash%% *}
[[ $config_hash == d4836c6c291859c758aa31c38273f0b22ecbce4b09f13cd67d56ce76b86dd2dd ]]
[[ $(jq -er .native_config_sha256 "$profile/source-composition.json") == "$config_hash" ]]
cp "$profile/SHA256SUMS" "$stage/parent-profile.sha256"
cat > "$stage/overlays" <<'FILES'
patches/boot/0062-ath11k-regulatory-status.patch
src/wlan/prepare-regulatory-status.sh
src/wlan/README.md
tests/fixtures/ath11k-regulatory-status-host.h
tests/ath11k-regulatory-status-contract.c
tests/ath11k-regulatory-status-contract.sh
tests/ath11k-regulatory-status-regression.sh
tests/ath11k-regulatory-status-package-contract.sh
FILES
while read -r relative; do
 [[ $relative =~ ^(src|tests|patches)/[a-zA-Z0-9_,./-]+$ && $relative != *..* ]]
 test ! -e "$profile/$relative"
 install -Dm644 "$owner/$relative" "$profile/$relative"
done < "$stage/overlays"
cat >> "$profile/prepare.sh" <<'PREPARE'

# Country-status observability only; every regulatory decision stays intact.
bash "$profile/src/wlan/prepare-regulatory-status.sh" "$kernel"
sha256sum "$profile/patches/boot/0062-ath11k-regulatory-status.patch" \
 "$kernel/drivers/net/wireless/ath/ath11k/wmi.c" \
 "$kernel/drivers/net/wireless/ath/ath11k/reg.c" >> "$output/abl-source-SHA256SUMS"
PREPARE
printf 'prepare.sh\n' >> "$stage/overlays"
while read -r expected relative; do
 relative=${relative#./}
 case $relative in source-commit|source-composition.json) continue;; esac
 if ! grep -Fxq "$relative" "$stage/overlays"; then
  printf '%s  %s\n' "$expected" "$profile/$relative" | sha256sum -c --quiet -
 fi
done < "$stage/parent-profile.sha256"
cp "$profile/source-composition.json" "$profile/source-composition-before-regulatory-status.json"
commit=$(git -C "$owner" rev-parse HEAD)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq -Rn '[inputs]' < "$stage/overlays" > "$stage/overlays.json"
jq --arg commit "$commit" --arg parent_hash "$parent_hash" --arg release "$release" --arg revision "$revision" \
 --slurpfile overlays "$stage/overlays.json" '. + {
 source_commit:$commit,source_mode:"retained2700-with-accurate-ath11k-country-status",
 parent_copr_build:11252415,parent_srpm_sha256:$parent_hash,
 parent_source_commit:"c0de80bf9f7f5ac18b4fb5ceb623342f285382ee",
 parent_header_sha256:"f4ea588bdf730995c63fea28dd9a1dc2b6b7508faa778a0b1017a4a205e83cd2",
 parent_payload_sha256:"0b2d7e79fd78fc95ea2c54b2b22aaf063a342891d0a9fd4131ee423bbeccfb89",
 parent_composition:"source-composition-before-regulatory-status.json",
 kernel_release:$release,rpm_revision:$revision,overlays:$overlays[0],
 ath11k_regulatory_status_diagnostics:1,ath11k_regulatory_policy_unchanged:true,
 ath11k_regulatory_decisions_unchanged:true,ath11k_original_refusal_errno:-22,
 ath11k_status_input_variants:["legacy","extended"],
 ath11k_diagnostic_scope:"status-assignment-before-log-and-refusal-context",
 ath11k_wire_protocol_unchanged:true,physical_acceptance:false,
 changed_kernel_files:((.changed_kernel_files + [
 "drivers/net/wireless/ath/ath11k/wmi.c","drivers/net/wireless/ath/ath11k/reg.c"])|unique)
 }' "$profile/source-composition-before-regulatory-status.json" > "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
 -cJf "$output/$archive" -C "$stage/unpacked" native-profile
[[ $(grep -Fxc '%global senemos_build_release 2700' "$spec") == 1 &&
 $(grep -Fxc 'uke_build_start=$SECONDS' "$spec") == 1 && $(grep -Fxc '%check' "$spec") == 1 ]]
awk -v revision="$revision" '
 /^%global senemos_build_release 2700$/ {$0="%global senemos_build_release " revision}
 /^uke_build_start=\$SECONDS$/ {
  print;print "bash native-profile/tests/ath11k-regulatory-status-regression.sh \"$PWD\"";next
 }
 /^%check$/ {
  print;print "bash native-profile/tests/ath11k-regulatory-status-package-contract.sh \"$PWD\" %{_uke_out}";next
 }
 /^%changelog$/ {
  print;print "* Wed Nov 04 2026 Uke contributors - 7.3.1-" revision
  print "- Report converted ath11k country status before logging and in refusals."
  print "- Preserve regulatory decisions and the complete qualified2700 cohort."
  print "- Require actual-old diagnostic failures, sanitizer and full module checks."
  print "";next
 }
 {print}
' "$spec" > "$stage/next.spec"
install -m644 "$stage/next.spec" "$spec"
sha256sum -c "$stage/retained-sources.sha256"
[[ $(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec") == "$release" ]]
