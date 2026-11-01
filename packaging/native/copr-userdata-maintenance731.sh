#!/usr/bin/env bash
# Retain the running 1003 source; expose read-only watchdog state for maintenance.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/../.."; pwd)
output=$(realpath -m "${1:?COPR result directory}")
parent_hash=a1e30e614267f9985fc75223bb49bc06bd9a0d2f00e30e8b99bc9bee1b113297
parent_url=https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable:custom:o82-avr-20261101/srpm-builds/11240068/senemos-uke-linux-kernel-mainline-7.3.1-1003.src.rpm
release=1040
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
mkdir -p "$output" "$stage/source" "$stage/profile" "$stage/boot"
[[ -z $(find "$output" -mindepth 1 -maxdepth 1 -print -quit) ]]
curl -fLsS --proto '=https' --proto-redir '=https' --max-time 240 "$parent_url" -o "$stage/parent.src.rpm"
printf '%s  %s\n' "$parent_hash" "$stage/parent.src.rpm" | sha256sum -c -
rpm2cpio "$stage/parent.src.rpm" > "$stage/source.cpio"
cpio -t --quiet < "$stage/source.cpio" > "$stage/members"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/members"
(cd "$stage/source"; cpio -idm --quiet --no-absolute-filenames < "$stage/source.cpio")
spec="$stage/source/senemos-uke-linux-kernel-mainline.spec"
grep -Fx '%global senemos_build_release 1003' "$spec"
tar -xJf "$stage/source/senemos-native-profile-7.3.1.tar.xz" -C "$stage/profile"
tar -xJf "$stage/source/senemos-uke-boot-recipe.tar.xz" -C "$stage/boot"
profile="$stage/profile/native-profile"
boot="$stage/boot/boot-recipe"
(cd "$profile"; sha256sum -c --status SHA256SUMS)
cmp "$boot/lock.json" "$stage/source/boot-payload.json"
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --status -)
cmp "$profile/native.config" "$boot/packaging/native/native.config"
cp "$profile/native.config" "$stage/parent.config"
[[ $(grep -Fxc '# CONFIG_WATCHDOG_SYSFS is not set' "$stage/parent.config") == 1 ]]
for config in "$profile/native.config" "$boot/packaging/native/native.config"; do
    sed -i 's/^# CONFIG_WATCHDOG_SYSFS is not set$/CONFIG_WATCHDOG_SYSFS=y/' "$config"
done
cmp "$profile/native.config" "$boot/packaging/native/native.config"
# Independently reverse the single admitted configuration change.
sed 's/^CONFIG_WATCHDOG_SYSFS=y$/# CONFIG_WATCHDOG_SYSFS is not set/' "$profile/native.config" > "$stage/reversed.config"
cmp "$stage/parent.config" "$stage/reversed.config"
commit=$(git -C "$root" rev-parse HEAD)
config_hash=$(sha256sum "$profile/native.config" | awk '{print $1}')
printf '%s\n' "$commit" > "$profile/source-commit"
jq -n --arg commit "$commit" --arg parent "$parent_hash" --arg config "$config_hash" \
    '{schema_version:1,date:"2026-11-01",source_mode:"retained-1003-with-watchdog-state-only",source_commit:$commit,parent_copr_build:11240068,parent_srpm_sha256:$parent,kernel_release:"7.3.1-1040",configuration_change:"CONFIG_WATCHDOG_SYSFS=y",native_config_sha256:$config,physical_test_record:false}' \
    > "$profile/source-composition-userdata1040.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > "$stage/profile-sums")
cp "$stage/profile-sums" "$profile/SHA256SUMS"
jq --arg hash "$config_hash" \
    '.source_assets |= map(if .path=="packaging/native/native.config" then .sha256=$hash else . end) | .source_origin="1 November 2026: retain the exact accepted 1003 source and boot recipe; enable only the standard read-only watchdog sysfs state interface. Partition conversion and physical boot acceptance remain separate."' \
    "$boot/lock.json" > "$stage/new-lock.json"
mv "$stage/new-lock.json" "$boot/lock.json"
cp "$boot/lock.json" "$stage/source/boot-payload.json"
(cd "$profile"; sha256sum -c --status SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --status -)
tar --sort=name --mtime=@1793534400 --owner=0 --group=0 --numeric-owner -cJf "$stage/source/senemos-native-profile-7.3.1.tar.xz" -C "$stage/profile" native-profile
tar --sort=name --mtime=@1793534400 --owner=0 --group=0 --numeric-owner -cJf "$stage/source/senemos-uke-boot-recipe.tar.xz" -C "$stage/boot" boot-recipe
sed -i -e "s/^%global senemos_build_release 1003$/%global senemos_build_release $release/" \
    -e '/^%check$/a grep -Fx CONFIG_WATCHDOG_SYSFS=y %{_uke_out}/.config' "$spec"
grep -Fx "%global senemos_build_release $release" "$spec"
grep -Fx 'grep -Fx CONFIG_WATCHDOG_SYSFS=y %{_uke_out}/.config' "$spec"
cp "$stage/source/"* "$output/"
printf '%s\n' 'Source preparation passed: pinned parent, complete checksums, both config copies, one configuration delta and final native config assertion.'
