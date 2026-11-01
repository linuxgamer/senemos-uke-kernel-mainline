#!/usr/bin/env bash
# COPR-only USB candidate retaining the complete qualified release1006 cohort.
set -Eeuo pipefail
export LC_ALL=C
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?COPR result directory}")
expected_release=7.3.1-1020
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline "$expected_release"
make -C "$owner" validate
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
curl --fail --location --silent --show-error --retry 3 --proto '=https' --proto-redir '=https' \
 https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-test:custom:power-20261031/srpm-builds/11240463/senemos-uke-linux-kernel-mainline-7.3.1-1006.src.rpm -o "$stage/base.src.rpm"
printf '%s  %s\n' 70f151855f727c9d83c3bedc35ff52dd60cb222b2d741818472dced458bcd60c "$stage/base.src.rpm" | sha256sum -c -
test "$(rpm -qp --qf '%{SOURCEPACKAGE}' "$stage/base.src.rpm")" = 1
rpm2cpio "$stage/base.src.rpm" > "$stage/base.cpio"
cpio -t --quiet < "$stage/base.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/base.cpio")
spec=$output/senemos-uke-linux-kernel-mainline.spec
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec")" = 7.3.1-1006
find "$output" -maxdepth 1 -type f ! -name "${spec##*/}" ! -name senemos-native-profile-7.3.1.tar.xz \
 -print0 | sort -z | xargs -0 sha256sum > "$stage/retained.sha256"
tar -tJf "$output/senemos-native-profile-7.3.1.tar.xz" > "$stage/archive.entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/archive.entries"
tar -xJf "$output/senemos-native-profile-7.3.1.tar.xz" -C "$stage/unpacked"
profile=$stage/unpacked/native-profile
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS)
grep -Fx fcbdae4b757732f0f0e3162c610f19abae290832 "$profile/source-commit"
cp "$profile/SHA256SUMS" "$stage/parent-profile.sha256"
cp "$profile/prepare.sh" "$stage/parent-prepare.sh"
cp "$profile/source-composition.json" "$profile/source-composition-parent7311006.json"
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
 . + {source_mode:"retained-release1006-with-usb-role-pm-correction",source_commit:$commit,
 parent_copr_build:11240463,parent_source_commit:"fcbdae4b757732f0f0e3162c610f19abae290832",
 parent_srpm_sha256:"70f151855f727c9d83c3bedc35ff52dd60cb222b2d741818472dced458bcd60c",
 parent_composition:"source-composition-parent7311006.json",adaptation_patches_unchanged:true,
 usb_role_pm_patch:"patches/usb/0001-qcom-system-role-pm.patch",
 observed_runtime_teardown_cause:"unverified",physical_acceptance:false}' \
 "$profile/source-composition-parent7311006.json" > "$profile/source-composition.json"
jq -e --slurpfile parent "$profile/source-composition-parent7311006.json" \
 -f "$owner/packaging/native/usb-role-pm-retention.jq" \
 "$profile/source-composition.json" >/dev/null
# A lost inherited setting must fail the same production retention check.
if jq 'del(.electrical_limits_unchanged)' "$profile/source-composition.json" | \
 jq -e --slurpfile parent "$profile/source-composition-parent7311006.json" \
 -f "$owner/packaging/native/usb-role-pm-retention.jq" >/dev/null; then
    echo 'Retention check admitted a missing inherited setting' >&2
    exit 1
fi
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner -cJf \
 "$output/senemos-native-profile-7.3.1.tar.xz" -C "$stage/unpacked" native-profile
test "$(grep -Fxc '%global senemos_build_release 1006' "$spec")" = 1
sed -i 's/^%global senemos_build_release 1006$/%global senemos_build_release 1020/' "$spec"
sha256sum -c "$stage/retained.sha256"
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec")" = "$expected_release"
