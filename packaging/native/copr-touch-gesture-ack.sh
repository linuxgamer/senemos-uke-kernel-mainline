#!/usr/bin/env bash
# COPR only: retain qualified 3000 and match the exact Uke gesture ACK path.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?Remote source result directory}")
revision=${2:?Fresh revision without Fedora suffix}
[[ $revision =~ ^[1-9][0-9]{3,5}$ ]]
release=7.3.1-$revision
[[ $(curl -fsS --max-time 45 https://copr.fedorainfracloud.org/api_3/build/11252621 | jq -er .state) == succeeded ]]
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline "$release"
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
curl -fLsS --retry 2 --proto '=https' --proto-redir '=https' \
 https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/11252621/senemos-uke-linux-kernel-mainline-7.3.1-3000.src.rpm \
 -o "$stage/parent.src.rpm"
[[ $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$stage/parent.src.rpm") == senemos-uke-linux-kernel-mainline-7.3.1-3000 ]]
[[ $(rpm -qp --qf '%{SHA256HEADER}' "$stage/parent.src.rpm") == ef3834764344db7e8cab3f9eb26c55424a65c6e1dc32153ee6651c4af0fbfcae ]]
[[ $(rpm -qp --qf '%{PAYLOADSHA256}' "$stage/parent.src.rpm") == c5956cf2b13628690d572197cc118612a67a6fc0394bc58c041d6f1cf31af69b ]]
rpmkeys --checksig --nosignature --verbose "$stage/parent.src.rpm"
parent_hash=$(sha256sum "$stage/parent.src.rpm"); parent_hash=${parent_hash%% *}
printf 'Verified complete parent3000 SRPM SHA-256: %s\n' "$parent_hash"
rpm2cpio "$stage/parent.src.rpm" > "$stage/parent.cpio"
cpio -t --quiet < "$stage/parent.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/parent.cpio")
spec=$output/senemos-uke-linux-kernel-mainline.spec
native_archive=senemos-native-profile-7.3.1.tar.xz
boot_archive=senemos-uke-boot-recipe.tar.xz
find "$output" -maxdepth 1 -type f ! -name "${spec##*/}" ! -name "$native_archive" \
 ! -name "$boot_archive" ! -name boot-payload.json -print0 | sort -z | xargs -0 sha256sum > "$stage/retained-sources.sha256"
for archive in "$native_archive" "$boot_archive"; do
 tar -tJf "$output/$archive" > "$stage/archive.entries"
 awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/archive.entries"
 tar -xJf "$output/$archive" -C "$stage/unpacked"
done
profile=$stage/unpacked/native-profile
boot=$stage/unpacked/boot-recipe
[[ $(cat "$profile/source-commit") == b1e1979e16719c08b1eac1bbbbf4afc9c6facc21 ]]
jq -e '.kernel_release=="7.3.1-3000" and .ath11k_regulatory_status_diagnostics==1 and
 .ath11k_regulatory_policy_unchanged and .ath11k_regulatory_decisions_unchanged and
 .wcd939x_telemetry_readonly==1 and .wcd939x_electrical_settings_unchanged and
 .qualified_ssc_large_report_check==11252237 and .ssc_indication_ids==[33,34] and
 .ssc_adsp_supplier_bound_gate==1 and .o82_regdma_resource=={start:"0x0af80000",size:"0x7000"} and
 (.o82_color_dma_enabled|not) and (.native_hdr_advertised|not) and
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
[[ $(sha256sum "$profile/native.config" | cut -d' ' -f1) == d4836c6c291859c758aa31c38273f0b22ecbce4b09f13cd67d56ce76b86dd2dd ]]
before=$owner/tests/fixtures/nt36532-before-gesture-ack.c
printf '%s  %s\n' a6b7f99b8a226c54f36dea8c58ab0176bf44012086c6908e005e97ab1703e6e3 "$before" | sha256sum -c --strict
cmp "$before" "$profile/src/input/nt36532-uke-protocol.c"
cmp "$before" "$boot/src/input/nt36532-uke-protocol.c"
cp "$profile/SHA256SUMS" "$stage/parent-profile.sha256"
cp "$boot/lock.json" "$stage/parent-boot-lock.json"
(cd "$boot"; find . -type f ! -name lock.json -print0 | sort -z | xargs -0 sha256sum) > "$stage/parent-boot.sha256"
cat > "$stage/overlays" <<'FILES'
src/input/nt36532-uke-protocol.c
tests/touch-gesture.c
tests/touch-protocol-contract.sh
tests/fixtures/nt36532-before-gesture-ack.c
tests/touch-gesture-ack-regression.sh
tests/touch-gesture-ack-package-contract.sh
docs/NT36532-PROTOCOL.md
FILES
: > "$stage/boot-overlays"
while read -r relative; do
 [[ $relative =~ ^(src|tests|docs)/[a-zA-Z0-9_,./-]+$ && $relative != *..* ]]
 mode=644
 [[ ! -e $profile/$relative ]] || mode=$(stat -c %a "$profile/$relative")
 install -Dm"$mode" "$owner/$relative" "$profile/$relative"
 if jq -e --arg path "$relative" '.source_assets[]|select(.path==$path)' "$boot/lock.json" >/dev/null; then
  mode=$(stat -c %a "$boot/$relative")
  install -Dm"$mode" "$owner/$relative" "$boot/$relative"
  printf '%s\n' "$relative" >> "$stage/boot-overlays"
  digest=$(sha256sum "$boot/$relative"); digest=${digest%% *}
  jq --arg path "$relative" --arg digest "$digest" '(.source_assets[]|select(.path==$path)|.sha256)=$digest' \
   "$boot/lock.json" > "$stage/lock.json"
  install -m644 "$stage/lock.json" "$boot/lock.json"
 fi
done < "$stage/overlays"
cat >> "$profile/prepare.sh" <<'PREPARE'

# The boot image and protocol tests must use this same updated C source.
cmp "$profile/src/input/nt36532-uke-protocol.c" \
 "$kernel/drivers/input/touchscreen/nt36532-uke/nt36532-uke-protocol.c"
sha256sum "$kernel/drivers/input/touchscreen/nt36532-uke/nt36532-uke-protocol.c" >> "$output/abl-source-SHA256SUMS"
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
cp "$profile/source-composition.json" "$profile/source-composition-before-gesture-ack.json"
commit=$(git -C "$owner" rev-parse HEAD)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq -Rn '[inputs]' < "$stage/overlays" > "$stage/overlays.json"
jq --arg commit "$commit" --arg parent_hash "$parent_hash" --arg release "$release" --arg revision "$revision" \
 --slurpfile overlays "$stage/overlays.json" '. + {
 source_commit:$commit,source_mode:"retained3000-with-OEM-acknowledged-gesture-settings",
 parent_copr_build:11252621,parent_srpm_sha256:$parent_hash,
 parent_source_commit:"b1e1979e16719c08b1eac1bbbbf4afc9c6facc21",
 parent_header_sha256:"ef3834764344db7e8cab3f9eb26c55424a65c6e1dc32153ee6651c4af0fbfcae",
 parent_payload_sha256:"c5956cf2b13628690d572197cc118612a67a6fc0394bc58c041d6f1cf31af69b",
 parent_composition:"source-composition-before-gesture-ack.json",
 kernel_release:$release,rpm_revision:$revision,overlays:$overlays[0],
 touch_gesture_setting_path:"OEM-mandatory-ACK-without-extra-getters",
 touch_gesture_setting_commands:[17,27],touch_gesture_setting_getter_queries:false,
 touch_coordinate_readback_preserved:true,touch_ack_retries:5,
 touch_mandatory_errors_preserved:true,touch_panel_order_unchanged:true,
 touch_firmware_calibration_unchanged:true,touch_command_failure_diagnostics:true,
 physical_acceptance:false,
 changed_kernel_files:((.changed_kernel_files + [
 "drivers/input/touchscreen/nt36532-uke/nt36532-uke-protocol.c"])|unique)
 }' "$profile/source-composition-before-gesture-ack.json" > "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --quiet -)
for tree in native-profile boot-recipe; do
 archive=$native_archive
 [[ $tree != boot-recipe ]] || archive=$boot_archive
 tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
  -cJf "$output/$archive" -C "$stage/unpacked" "$tree"
done
install -m644 "$boot/lock.json" "$output/boot-payload.json"
[[ $(grep -Fxc '%global senemos_build_release 3000' "$spec") == 1 &&
 $(grep -Fxc 'uke_build_start=$SECONDS' "$spec") == 1 && $(grep -Fxc '%check' "$spec") == 1 ]]
awk -v revision="$revision" '
 /^%global senemos_build_release 3000$/ {$0="%global senemos_build_release " revision}
 /^uke_build_start=\$SECONDS$/ {
  print;print "bash native-profile/tests/touch-gesture-ack-regression.sh";next
 }
 /^%check$/ {
  print;print "bash native-profile/tests/touch-gesture-ack-package-contract.sh \"$PWD\" %{_uke_out}";next
 }
 /^%changelog$/ {
  print;print "* Wed Nov 04 2026 Uke contributors - 7.3.1-" revision
  print "- Use OEM acknowledged gesture setters without extra diagnostic queries."
  print "- Retain coordinate readback, mandatory errors and the complete3000 cohort."
  print "- Require actual-old sequence/query failures and corrected native checks."
  print "";next
 }
 {print}
' "$spec" > "$stage/next.spec"
install -m644 "$stage/next.spec" "$spec"
sha256sum -c "$stage/retained-sources.sha256"
[[ $(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec") == "$release" ]]
