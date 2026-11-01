#!/usr/bin/env bash
# COPR-only USB candidate from the full qualified running-116 source.
set -Eeuo pipefail
export LC_ALL=C
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?COPR result directory}")
expected_release=7.3.1-1005
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline "$expected_release"
make -C "$owner" validate
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
curl --fail --location --silent --show-error --retry 3 --proto '=https' --proto-redir '=https' \
 https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-test:custom:power-20261031/srpm-builds/11239905/senemos-uke-linux-kernel-mainline-7.3.1-116.src.rpm -o "$stage/base.src.rpm"
printf '%s  %s\n' e376800a58f3d1b91e89b5f88b678da950e74157035db7944edbf306cc7f822c "$stage/base.src.rpm" | sha256sum -c -
test "$(rpm -qp --qf '%{SOURCEPACKAGE}' "$stage/base.src.rpm")" = 1
rpm2cpio "$stage/base.src.rpm" > "$stage/base.cpio"
cpio -t --quiet < "$stage/base.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/base.cpio")
spec=$output/senemos-uke-linux-kernel-mainline.spec
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec")" = 7.3.1-116
find "$output" -maxdepth 1 -type f ! -name "${spec##*/}" ! -name senemos-native-profile-7.3.1.tar.xz \
 -print0 | sort -z | xargs -0 sha256sum > "$stage/retained.sha256"
tar -tJf "$output/senemos-native-profile-7.3.1.tar.xz" > "$stage/archive.entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/archive.entries"
tar -xJf "$output/senemos-native-profile-7.3.1.tar.xz" -C "$stage/unpacked"
profile=$stage/unpacked/native-profile
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS)
grep -Fx d9d48e916070c95d19518dda4aa8bcf11ed3d2b4 "$profile/source-commit"
cp "$profile/SHA256SUMS" "$stage/parent-profile.sha256"
cp "$profile/prepare.sh" "$stage/parent-prepare.sh"
cp "$profile/source-composition.json" "$profile/source-composition-parent731116.json"
for relative in patches/usb/0001-qcom-system-role-pm.patch tests/usb-role-pm-contract.sh tests/usb-role-pm-fixture.c; do
    test ! -e "$profile/$relative"
    install -Dm644 "$owner/$relative" "$profile/$relative"
done
cat >> "$profile/prepare.sh" <<'PREPARE'
# Keep the complete retained adaptation and apply the isolated role/PM correction last.
cp "$kernel/drivers/usb/dwc3/dwc3-qcom.c" "$output/dwc3-qcom-before-role-pm.c"
git -C "$kernel" apply --check "$profile/patches/usb/0001-qcom-system-role-pm.patch"
git -C "$kernel" apply "$profile/patches/usb/0001-qcom-system-role-pm.patch"
CC=clang bash "$profile/tests/usb-role-pm-contract.sh" \
    "$kernel/drivers/usb/dwc3/dwc3-qcom.c" "$output/dwc3-qcom-before-role-pm.c"
PREPARE
cmp -n "$(stat -c %s "$stage/parent-prepare.sh")" "$stage/parent-prepare.sh" "$profile/prepare.sh"
while read -r expected relative; do
    relative=${relative#./}
    case $relative in source-commit|source-composition.json|prepare.sh) continue;; esac
    printf '%s  %s\n' "$expected" "$profile/$relative" | sha256sum -c -
done < "$stage/parent-profile.sha256"
# Exercise the actual retained functions before emitting a kernel SRPM.
mkdir -p "$stage/fixture"
tar -xJf "$output/linux-7.3.1.tar.xz" --strip-components=1 -C "$stage/fixture" \
 linux-7.3.1/drivers/usb/dwc3/dwc3-qcom.c
git -C "$stage/fixture" init -q
while IFS= read -r patch; do
    [[ -n $patch && $patch != \#* ]] || continue
    if rg -q '^(diff --git a/|--- a/|\+\+\+ b/)drivers/usb/dwc3/dwc3-qcom.c' "$profile/patches/7.3.0/$patch"; then
        git -C "$stage/fixture" apply --include=drivers/usb/dwc3/dwc3-qcom.c "$profile/patches/7.3.0/$patch"
    fi
done < "$profile/patches/7.3.0/series"
baseline=$stage/baseline-qcom.c
cp "$stage/fixture/drivers/usb/dwc3/dwc3-qcom.c" "$baseline"
printf '%s  %s\n' 5ad51c8d48c9f58d13c3517e2d588b429020ca715563f60ab3e7fba4ff6920c1 "$baseline" | sha256sum -c -
git -C "$stage/fixture" apply "$owner/patches/usb/0001-qcom-system-role-pm.patch"
CC=clang bash "$owner/tests/usb-role-pm-contract.sh" "$stage/fixture/drivers/usb/dwc3/dwc3-qcom.c" "$baseline"
commit=$(git -C "$owner" rev-parse HEAD)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq --arg commit "$commit" '
 . + {source_mode:"retained-release116-with-usb-role-pm-correction",source_commit:$commit,
 parent_copr_build:11239905,parent_source_commit:"d9d48e916070c95d19518dda4aa8bcf11ed3d2b4",
 parent_srpm_sha256:"e376800a58f3d1b91e89b5f88b678da950e74157035db7944edbf306cc7f822c",
 parent_composition:"source-composition-parent731116.json",adaptation_patches_unchanged:true,
 usb_role_pm_patch:"patches/usb/0001-qcom-system-role-pm.patch",
 observed_runtime_teardown_cause:"unverified",physical_acceptance:false}' \
 "$profile/source-composition-parent731116.json" > "$profile/source-composition.json"
jq -e --slurpfile parent "$profile/source-composition-parent731116.json" '
 [.audio_profile,.capture_channels,.capture_channel_counts,.capture_analog_inputs,
  .input_qualification,.analog_gain_indices,.digital_gain_db,.gain_applied_before_capture,
  .desktop_data_owner,.lmh_policy_lifecycle_fix,.cpucp_observer,.cpucp_version_negotiation,
  .cpucp_required_version,.boost_default_changed,.ignore_unused_removed] ==
 ($parent[0] | [.audio_profile,.capture_channels,.capture_channel_counts,.capture_analog_inputs,
  .input_qualification,.analog_gain_indices,.digital_gain_db,.gain_applied_before_capture,
  .desktop_data_owner,.lmh_policy_lifecycle_fix,.cpucp_observer,.cpucp_version_negotiation,
  .cpucp_required_version,.boost_default_changed,.ignore_unused_removed]) and
 .capture_channels==4 and .capture_channel_counts==[1,2,4] and .adaptation_patch_count==122' \
 "$profile/source-composition.json" >/dev/null
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner -cJf \
 "$output/senemos-native-profile-7.3.1.tar.xz" -C "$stage/unpacked" native-profile
test "$(grep -Fxc '%global senemos_build_release 116' "$spec")" = 1
sed -i 's/^%global senemos_build_release 116$/%global senemos_build_release 1005/' "$spec"
sha256sum -c "$stage/retained.sha256"
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec")" = "$expected_release"
