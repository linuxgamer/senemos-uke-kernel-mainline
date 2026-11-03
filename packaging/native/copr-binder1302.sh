#!/usr/bin/env bash
# COPR only: retain release 1301 and enable built-in Binder IPC/binderfs.
set -Eeuo pipefail
trap 'status=$?; printf "Binder source preparation failed at line %s (exit %s)\n" "$LINENO" "$status" >&2; exit "$status"' ERR
export LC_ALL=C
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?COPR result directory}")
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline 7.3.1-1302
parent_hash=83b76251f124193609cb2da1f04a1f3100287875534bf1f8504e0ffa87f76d4b
curl -fLsS --retry 2 --proto '=https' --proto-redir '=https' \
 https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/11251200/senemos-uke-linux-kernel-mainline-7.3.1-1301.src.rpm -o "$stage/base.src.rpm"
printf '%s  %s\n' "$parent_hash" "$stage/base.src.rpm" | sha256sum -c -
[[ $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$stage/base.src.rpm") == senemos-uke-linux-kernel-mainline-7.3.1-1301 ]]
rpmkeys --checksig --nosignature --verbose "$stage/base.src.rpm"
rpm2cpio "$stage/base.src.rpm" > "$stage/base.cpio"
cpio -t --quiet < "$stage/base.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/base.cpio")
spec=$output/senemos-uke-linux-kernel-mainline.spec
printf '%s  %s\n' 1df9eadd11608c2ad99a1728af12fcc5ddc20d7e8bf412c8b87bce72010bae6f "$spec" | sha256sum -c -
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
[[ $(cat "$profile/source-commit") == 1c77e13fe0efd77053add9df9ebc7ae484fdbd48 ]]
jq -e '.kernel_release=="7.3.1-1301" and .touch_recovery_attempts_per_powered_epoch==1 and
 .panel_variants==["o82_36_02_0a","o82_42_02_0b"] and .touch_variants==["tianma","csot"] and
 .native_memlat_groups==["llcc","l3"]' "$profile/source-composition.json" >/dev/null
cmp "$profile/native.config" "$boot/packaging/native/native.config"
cmp "$output/boot-payload.json" "$boot/lock.json"
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS
 find . -type f ! -name SHA256SUMS ! -name source-commit ! -name source-composition.json \
  ! -name native.config -print0 | sort -z | xargs -0 sha256sum > "$stage/retained-profile.sha256")
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c -
 find . -type f ! -path './lock.json' ! -path './packaging/native/native.config' \
  -print0 | sort -z | xargs -0 sha256sum > "$stage/retained-boot.sha256")
# Use the same independent Binder settings in the ordinary native profile.
awk '/^(CONFIG_ANDROID_BINDER|# CONFIG_ANDROID_BINDER)/' "$owner/packaging/native/native.config" > "$stage/binder.config"
[[ $(wc -l < "$stage/binder.config") == 5 ]]
for setting in 'CONFIG_ANDROID_BINDER_IPC=y' 'CONFIG_ANDROID_BINDERFS=y' \
 'CONFIG_ANDROID_BINDER_DEVICES=""' '# CONFIG_ANDROID_BINDER_IPC_RUST is not set' \
 '# CONFIG_ANDROID_BINDER_ALLOC_KUNIT_TEST is not set'; do
 grep -Fx "$setting" "$stage/binder.config"
done
[[ $(grep -Fxc '# CONFIG_ANDROID_BINDER_IPC is not set' "$profile/native.config") == 1 ]]
awk -v fragment="$stage/binder.config" '
 /^# CONFIG_ANDROID_BINDER_IPC is not set$/ {
  while ((getline line < fragment)>0) print line
  close(fragment); next
 }
 {print}
' "$profile/native.config" > "$stage/native.config"
install -m644 "$stage/native.config" "$profile/native.config"
install -m644 "$stage/native.config" "$boot/packaging/native/native.config"
config_hash=$(sha256sum "$stage/native.config"); config_hash=${config_hash%% *}
jq --arg hash "$config_hash" '(.source_assets[]|select(.path=="packaging/native/native.config")|.sha256)=$hash' \
 "$boot/lock.json" > "$stage/lock.json"
install -m644 "$stage/lock.json" "$boot/lock.json"
install -m644 "$stage/lock.json" "$output/boot-payload.json"
cp "$profile/source-composition.json" "$profile/source-composition-before1302.json"
commit=$(git -C "$owner" rev-parse HEAD)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq --arg commit "$commit" --arg parent_hash "$parent_hash" --arg config_hash "$config_hash" '. + {
 source_commit:$commit,source_mode:"retained1301-with-native-binder",
 parent_copr_build:11251200,parent_srpm_sha256:$parent_hash,
 parent_source_commit:"1c77e13fe0efd77053add9df9ebc7ae484fdbd48",
 parent_composition:"source-composition-before1302.json",kernel_release:"7.3.1-1302",rpm_revision:"1302",
 overlays:["native.config","boot-recipe/packaging/native/native.config","boot-recipe/lock.json"],
 kernel_driver_source_unchanged:true,changed_kernel_files:[],
 native_config_sha256:$config_hash,binder_ipc_builtin:true,binderfs_builtin:true,
 binder_static_devices:[],el2_policy_unchanged:true,automatic_policy_unchanged:true,
 physical_acceptance:false,waydroid_tested:false
 }' "$profile/source-composition-before1302.json" > "$profile/source-composition.json"
(cd "$profile"; sha256sum -c "$stage/retained-profile.sha256"
 find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$boot"; sha256sum -c "$stage/retained-boot.sha256"
 jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c -)
for tree in native-profile boot-recipe; do
 archive=$native_archive
 [[ $tree != boot-recipe ]] || archive=$boot_archive
 tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner -cJf "$output/$archive" -C "$stage/unpacked" "$tree"
done
[[ $(grep -Fxc '%global senemos_build_release 1301' "$spec") == 1 ]]
[[ $(grep -Fxc '%check' "$spec") == 1 ]]
awk '
 /^%global senemos_build_release 1301$/ {$0="%global senemos_build_release 1302"}
 /^%check$/ {
  print
  print "grep -Fx '\''CONFIG_ANDROID_BINDER_IPC=y'\'' %{_uke_out}/.config"
  print "grep -Fx '\''CONFIG_ANDROID_BINDERFS=y'\'' %{_uke_out}/.config"
  print "grep -Fx '\''CONFIG_ANDROID_BINDER_DEVICES=\"\"'\'' %{_uke_out}/.config"
  print "grep -Fx '\''CONFIG_MEMFD_CREATE=y'\'' %{_uke_out}/.config"
  print "test -s %{_uke_out}/drivers/android/binder.o"
  print "test -s %{_uke_out}/drivers/android/binderfs.o"
  print "grep -Eq '\'' [tT] binder_init$'\'' %{_uke_out}/System.map"
  print "grep -Eq '\'' [tT] binderfs_init$'\'' %{_uke_out}/System.map"
  next
 }
 /^%changelog$/ {
  print
  print "* Tue Nov 03 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-1302"
  print "- Enable built-in Binder IPC and binderfs in the normal ARM64 kernel."
  print "- Retain release1301 drivers, suppliers, touch recovery and boot policy."
  print ""
  next
 }
 {print}
' "$spec" > "$stage/next.spec"
mv "$stage/next.spec" "$spec"
sha256sum -c "$stage/retained-sources.sha256"
[[ $(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec") == 7.3.1-1302 ]]
