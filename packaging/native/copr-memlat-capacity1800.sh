#!/usr/bin/env bash
# COPR only: retain qualified 1710 and admit adaptive L3 map constraints.
set -Eeuo pipefail
trap 'status=$?; printf "MEMLAT source preparation failed at line %s (exit %s)\n" "$LINENO" "$status" >&2; exit "$status"' ERR
export LC_ALL=C
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?COPR result directory}")
[[ $(curl -fLsS --max-time 45 https://copr.fedorainfracloud.org/api_3/build/11251648 | jq -er .state) == succeeded ]]
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline 7.3.1-1800
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
curl -fLsS --retry 2 --proto '=https' --proto-redir '=https' \
 https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/11251648/senemos-uke-linux-kernel-mainline-7.3.1-1710.src.rpm \
 -o "$stage/base.src.rpm"
[[ $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$stage/base.src.rpm") == senemos-uke-linux-kernel-mainline-7.3.1-1710 ]]
[[ $(rpm -qp --qf '%{SHA256HEADER}' "$stage/base.src.rpm") == 5b9f3e5ec2bc2a505f34821cc8e90f7f32ca7fc49eccc0ba73e9d796b2ce501f ]]
[[ $(rpm -qp --qf '%{PAYLOADSHA256}' "$stage/base.src.rpm") == a12ed13c9004df6b620745658a0f0cad42b7b2f6e72297f8150005808389329d ]]
rpmkeys --checksig --nosignature --verbose "$stage/base.src.rpm"
parent_hash=$(sha256sum "$stage/base.src.rpm");parent_hash=${parent_hash%% *}
printf 'Verified complete parent1710 SRPM SHA-256: %s\n' "$parent_hash"
rpm2cpio "$stage/base.src.rpm" > "$stage/base.cpio"
cpio -t --quiet < "$stage/base.cpio" | awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}'
mkdir -p "$output" "$stage/unpacked"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/base.cpio")
spec=$output/senemos-uke-linux-kernel-mainline.spec
native_archive=senemos-native-profile-7.3.1.tar.xz
boot_archive=senemos-uke-boot-recipe.tar.xz
find "$output" -maxdepth 1 -type f ! -name "${spec##*/}" \
 ! -name "$native_archive" ! -name "$boot_archive" ! -name boot-payload.json \
 -print0 | sort -z | xargs -0 sha256sum > "$stage/retained-sources.sha256"
for archive in "$native_archive" "$boot_archive"; do
 tar -tJf "$output/$archive" | awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}'
 tar -xJf "$output/$archive" -C "$stage/unpacked"
done
profile=$stage/unpacked/native-profile
boot=$stage/unpacked/boot-recipe
[[ $(cat "$profile/source-commit") == 6baa0bcfa21c456c156c7d6a9ce8d58ac3561005 ]]
jq -e '.kernel_release=="7.3.1-1710" and .native_ssc_iio_abi==1 and
 .ssc_temperature_unit=="millicelsius" and .nfc_role=="type2-tag" and
 .nfc_atomic_memory_read and .nfc_system_wakeup and .ir_explicit_word_bits==16 and
 .rtc_backend=="qseecom-uefisecapp-RTCInfo" and .binder_ipc_builtin and .binderfs_builtin and
 .touch_recovery_attempts_per_powered_epoch==1 and .native_memlat_groups==["llcc","l3"] and
 .panel_variants==["o82_36_02_0a","o82_42_02_0b"] and .touch_variants==["tianma","csot"]' \
 "$profile/source-composition.json" >/dev/null
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --quiet -)
cmp "$profile/native.config" "$boot/packaging/native/native.config"
cmp "$boot/lock.json" "$output/boot-payload.json"
cp "$profile/SHA256SUMS" "$stage/parent-profile.sha256"
cp "$boot/lock.json" "$stage/parent-boot-lock.json"
(cd "$boot"; find . -type f ! -name lock.json -print0 | sort -z | xargs -0 sha256sum) > "$stage/parent-boot.sha256"
install -Dm644 "$profile/src/power/uke-memlat.c" "$profile/tests/fixtures/memlat-before-capacity.c"
cat > "$stage/overlays" <<'FILES'
src/power/uke-memlat.c
tests/memlat-lifecycle-contract.sh
docs/POWER-MEMLAT.md
FILES
: > "$stage/boot-overlays"
while read -r relative; do
 install -Dm644 "$owner/$relative" "$profile/$relative"
 if jq -e --arg path "$relative" '.source_assets[]|select(.path==$path)' "$boot/lock.json" >/dev/null; then
  install -Dm644 "$owner/$relative" "$boot/$relative"
  printf '%s\n' "$relative" >> "$stage/boot-overlays"
  digest=$(sha256sum "$boot/$relative");digest=${digest%% *}
  jq --arg path "$relative" --arg digest "$digest" \
   '(.source_assets[]|select(.path==$path)|.sha256)=$digest' "$boot/lock.json" > "$stage/lock.json"
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
config_hash=$(sha256sum "$profile/native.config");config_hash=${config_hash%% *}
cp "$profile/source-composition.json" "$profile/source-composition-before1800.json"
commit=$(git -C "$owner" rev-parse HEAD)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq --arg commit "$commit" --arg parent_hash "$parent_hash" --arg config_hash "$config_hash" '. + {
 source_commit:$commit,source_mode:"retained1710-with-adaptive-l3-capacity",
 parent_copr_build:11251648,parent_srpm_sha256:$parent_hash,
 parent_source_commit:"6baa0bcfa21c456c156c7d6a9ce8d58ac3561005",
 parent_header_sha256:"5b9f3e5ec2bc2a505f34821cc8e90f7f32ca7fc49eccc0ba73e9d796b2ce501f",
 parent_payload_sha256:"a12ed13c9004df6b620745658a0f0cad42b7b2f6e72297f8150005808389329d",
 parent_composition:"source-composition-before1800.json",kernel_release:"7.3.1-1800",rpm_revision:"1800",
 overlays:["src/power/uke-memlat.c","tests/memlat-lifecycle-contract.sh","docs/POWER-MEMLAT.md"],
 native_config_sha256:$config_hash,native_config_digest_scope:"native-profile/native.config",
 kernel_driver_source_unchanged:false,
 changed_kernel_files:["drivers/soc/qcom/uke-memlat.c"],
 memlat_l3_capacity:"ERANGE-only-descending-OEM-map",
 memlat_l3_ceiling:"admitted-mapped-request-not-clock-telemetry",
 memlat_strict_provider_unchanged:true,memlat_llcc_policy_unchanged:true,
 electrical_limits_unchanged:true,firmware_payload_included:false,physical_acceptance:false
 }' "$profile/source-composition-before1800.json" > "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --quiet -)
for tree in native-profile boot-recipe; do
 archive=$native_archive
 [[ $tree != boot-recipe ]] || archive=$boot_archive
 tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner -cJf "$output/$archive" -C "$stage/unpacked" "$tree"
done
install -m644 "$boot/lock.json" "$output/boot-payload.json"
[[ $(grep -Fxc '%global senemos_build_release 1710' "$spec") == 1 ]]
[[ $(grep -Fxc 'uke_build_start=$SECONDS' "$spec") == 1 ]]
awk '
 /^%global senemos_build_release 1710$/ {$0="%global senemos_build_release 1800"}
 /^uke_build_start=\$SECONDS$/ {
  print
  print "cmp native-profile/src/power/uke-memlat.c drivers/soc/qcom/uke-memlat.c"
  print "ulimit -c 0"
  print "old_memlat_log=$(mktemp)"
  print "set +e"
  print "CC=clang SANITIZE=0 UKE_MEMLAT_SOURCE=\"$PWD/native-profile/tests/fixtures/memlat-before-capacity.c\" bash native-profile/tests/memlat-lifecycle-contract.sh > \"$old_memlat_log\" 2>&1"
  print "old_memlat_status=$?"
  print "set -e"
  print "if test \"$old_memlat_status\" != 134; then cat \"$old_memlat_log\"; exit 1; fi"
  print "grep -Fq '\''Adaptive L3 must retain its highest admitted map vote'\'' \"$old_memlat_log\""
  print "unlink \"$old_memlat_log\""
  print "echo '\''Original adaptive L3 cannot admit a bounded map request (expected status134)'\''"
  print "CC=clang SANITIZE=0 bash native-profile/tests/memlat-lifecycle-contract.sh"
  print "CC=clang SANITIZE=1 bash native-profile/tests/memlat-lifecycle-contract.sh"
  next
 }
 /^%changelog$/ {
  print
  print "* Tue Nov 03 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-1800"
  print "- Bound adaptive L3 map requests to provider-admitted OEM points."
  print "- Preserve transport/PM errors, strict provider checks and the complete1710 cohort."
  print "- Compute config provenance from retained bytes and record the exact parent."
  print "";next
 }
 {print}
' "$spec" > "$stage/next.spec"
install -m644 "$stage/next.spec" "$spec"
sha256sum -c "$stage/retained-sources.sha256"
[[ $(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec") == 7.3.1-1800 ]]
