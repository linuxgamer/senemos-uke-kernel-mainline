#!/usr/bin/env bash
# COPR only: retain qualified1300, suppliers/MEMLAT and add bounded touch recovery.
set -Eeuo pipefail
trap 'status=$?; printf "Source preparation failed at line %s (exit %s)\n" "$LINENO" "$status" >&2; exit "$status"' ERR
export LC_ALL=C
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?COPR result directory}")
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline 7.3.1-1301
curl -fLsS --retry 2 --proto '=https' --proto-redir '=https' \
 https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/11251037/senemos-uke-linux-kernel-mainline-7.3.1-1300.src.rpm -o "$stage/base.src.rpm"
parent_hash=$(sha256sum "$stage/base.src.rpm")
parent_hash=${parent_hash%% *}
printf 'Retained parent source RPM SHA-256: %s\n' "$parent_hash"
[[ $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$stage/base.src.rpm") == senemos-uke-linux-kernel-mainline-7.3.1-1300 ]]
[[ $(rpm -qp --qf '%{SHA256HEADER}' "$stage/base.src.rpm") == 91fc6239e8c9d9aa3f210682ddffb9c01c20cb68252c7b48d16574fa64b83d1f ]]
[[ $(rpm -qp --qf '%{PAYLOADSHA256}' "$stage/base.src.rpm") == 45348b8348a4ae1205e39f0cdfc3a36603905f98159a2e8ad0dd81179973374c ]]
rpmkeys --checksig --nosignature --verbose "$stage/base.src.rpm"
rpm2cpio "$stage/base.src.rpm" > "$stage/base.cpio"
cpio -t --quiet < "$stage/base.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/base.cpio")
spec=$output/senemos-uke-linux-kernel-mainline.spec
printf '%s  %s\n' f7aac91bcb8057aa3d0ee5bc6725218f296fb9d9f47bd097e99b2d8c1db476d0 "$spec" | sha256sum -c -
archive=senemos-native-profile-7.3.1.tar.xz
find "$output" -maxdepth 1 -type f ! -name "${spec##*/}" ! -name "$archive" \
 -print0 | sort -z | xargs -0 sha256sum > "$stage/retained-sources.sha256"
tar -tJf "$output/$archive" > "$stage/archive.entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/archive.entries"
tar -xJf "$output/$archive" -C "$stage/unpacked"
profile=$stage/unpacked/native-profile
[[ $(cat "$profile/source-commit") == 65c4c4716786af263dd1963ea09c59e547221e03 ]]
jq -e '.kernel_release=="7.3.1-1300" and .panel_variants==["o82_36_02_0a","o82_42_02_0b"] and .touch_variants==["tianma","csot"] and .native_memlat_groups==["llcc","l3"]' "$profile/source-composition.json" >/dev/null
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS
 find . -type f ! -name SHA256SUMS ! -name source-commit ! -name source-composition.json \
  ! -path './src/input/nt36532-uke-spi.c' ! -path './tests/touch-transport.c' \
  ! -path './tests/touch-transport-contract.sh' -print0 | sort -z | xargs -0 sha256sum > "$stage/retained-profile.sha256")
printf '%s  %s\n' c68ae90d832e9b880fbf28840bedea56648df57afea262eea059e402c18af851 "$profile/src/input/nt36532-uke-spi.c" | sha256sum -c -
test ! -e "$profile/tests/fixtures/touch-before-recovery.c"
install -Dm644 "$profile/src/input/nt36532-uke-spi.c" "$profile/tests/fixtures/touch-before-recovery.c"
for path in src/input/nt36532-uke-spi.c tests/touch-transport.c tests/touch-transport-contract.sh; do
 install -m644 "$owner/$path" "$profile/$path"
done
cp "$profile/source-composition.json" "$profile/source-composition-before1301.json"
commit=$(git -C "$owner" rev-parse HEAD)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq --arg commit "$commit" --arg parent_hash "$parent_hash" '. + {
 source_commit:$commit,source_mode:"retained1300-with-bounded-native-touch-recovery",
 parent_copr_build:11251037,parent_srpm_sha256:$parent_hash,
 parent_source_commit:"65c4c4716786af263dd1963ea09c59e547221e03",
 parent_header_sha256:"91fc6239e8c9d9aa3f210682ddffb9c01c20cb68252c7b48d16574fa64b83d1f",
 parent_payload_sha256:"45348b8348a4ae1205e39f0cdfc3a36603905f98159a2e8ad0dd81179973374c",
 overlays:["src/input/nt36532-uke-spi.c","tests/touch-transport.c","tests/touch-transport-contract.sh"],
 parent_composition:"source-composition-before1301.json",kernel_release:"7.3.1-1301",rpm_revision:"1301",
 kernel_driver_source_unchanged:false,
 changed_kernel_files:["drivers/input/touchscreen/nt36532-uke/nt36532-uke-spi.c"],
 touch_recovery_attempts_per_powered_epoch:1,firmware_payload_included:false,
 automatic_policy_unchanged:true,physical_acceptance:false
 }' "$profile/source-composition-before1301.json" > "$profile/source-composition.json"
(cd "$profile"; sha256sum -c "$stage/retained-profile.sha256"
 find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner -cJf "$output/$archive" -C "$stage/unpacked" native-profile
[[ $(grep -Fxc 'BuildRequires: compiler-rt' "$spec") == 1 ]]
for line in '%global senemos_build_release 1300' 'bash native-profile/prepare.sh "$PWD"' 'uke_build_start=$SECONDS'; do
 [[ $(grep -Fxc "$line" "$spec") == 1 ]]
done
awk '
 /^%global senemos_build_release 1300$/ {$0="%global senemos_build_release 1301"}
 /^bash native-profile\/prepare.sh "\$PWD"$/ {
  print
  print "cmp native-profile/src/input/nt36532-uke-spi.c drivers/input/touchscreen/nt36532-uke/nt36532-uke-spi.c"
  next
 }
 /^uke_build_start=\$SECONDS$/ {
  print "ulimit -c 0"
  print "touch_before_log=$(mktemp)"
  print "set +e"
  print "UKE_TOUCH_SOURCE=\"$PWD/native-profile/tests/fixtures/touch-before-recovery.c\" CC=clang bash native-profile/tests/touch-transport-contract.sh > \"$touch_before_log\" 2>&1"
  print "touch_before_status=$?"
  print "set -e"
  print "if test \"$touch_before_status\" != 134; then cat \"$touch_before_log\"; exit 1; fi"
  print "grep -Fq '\''!touch.fault && touch.recovery_attempts == 1'\'' \"$touch_before_log\""
  print "rm -f -- \"$touch_before_log\""
  print "echo '\''Original touch driver cannot recover a transient read fault (expected status134)'\''"
  print "UKE_TOUCH_SANITIZE=1 CC=clang bash native-profile/tests/touch-transport-contract.sh"
 }
 /^%changelog$/ {
  print
  print "* Tue Nov 03 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-1301"
  print "- Permit one verified native touch recovery per powered lifecycle."
  print "- Re-arm on panel/PM restoration and expose value-free diagnostic counters."
  print ""
  next
 }
 {print}
' "$spec" > "$stage/next.spec"
mv "$stage/next.spec" "$spec"
sha256sum -c "$stage/retained-sources.sha256"
[[ $(grep -Fxc 'UKE_TOUCH_SANITIZE=1 CC=clang bash native-profile/tests/touch-transport-contract.sh' "$spec") == 1 ]]
[[ $(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec") == 7.3.1-1301 ]]
