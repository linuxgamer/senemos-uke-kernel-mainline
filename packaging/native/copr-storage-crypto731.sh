#!/bin/bash
# COPR-only: preserve the qualified release115 source and enable storage crypto.
set -Eeuo pipefail
export LC_ALL=C
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?COPR result directory}")
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline 7.3.1-116
make -C "$owner" validate
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
curl --fail --location --silent --show-error --retry 3 --proto '=https' --proto-redir '=https' \
 https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/11239822/senemos-uke-linux-kernel-mainline-7.3.1-115.src.rpm -o "$stage/base.src.rpm"
printf '%s  %s\n' c55c77bc350c4bd39047683bfa41ba5d52d1a99e93735dfd80bb9074586a15f0 "$stage/base.src.rpm" | sha256sum -c -
test "$(rpm -qp --qf '%{SOURCEPACKAGE}' "$stage/base.src.rpm")" = 1
rpm2cpio "$stage/base.src.rpm" > "$stage/base.cpio"
cpio -t --quiet < "$stage/base.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/{bad=1} END{exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/base.cpio")
spec=senemos-uke-linux-kernel-mainline.spec
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$output/$spec")" = 7.3.1-115
find "$output" -maxdepth 1 -type f ! -name "$spec" ! -name senemos-native-profile-7.3.1.tar.xz \
 ! -name senemos-uke-boot-recipe.tar.xz ! -name boot-payload.json -print0 | sort -z | xargs -0 sha256sum > "$stage/retained.sha256"
for archive in senemos-native-profile-7.3.1.tar.xz senemos-uke-boot-recipe.tar.xz; do
    tar -tJf "$output/$archive" | awk '/^\/|(^|\/)\.\.($|\/)/{bad=1} END{exit bad}'
    tar -xJf "$output/$archive" -C "$stage/unpacked"
done
profile=$stage/unpacked/native-profile
boot=$stage/unpacked/boot-recipe
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS)
grep -Fxq 8983163763f708ec940b349ebb81ab43cc3725c3 "$profile/source-commit"
cp "$profile/SHA256SUMS" "$stage/parent-profile.sha256"
cp "$profile/source-composition.json" "$profile/source-composition-parent731115.json"
overlays=(packaging/native/native.config src/boot/build-payload.sh tests/storage-crypto-contract.sh)
: > "$stage/overlays"
for relative in "${overlays[@]}"; do
    destination=$relative
    [[ $relative != packaging/native/native.config ]] || destination=native.config
    install -Dm644 "$owner/$relative" "$profile/$destination"
    install -Dm644 "$owner/$relative" "$boot/$relative"
    printf '%s\n' "$destination" >> "$stage/overlays"
done
# No inherited implementation is replaced outside the declared overlay.
while read -r expected relative; do
    relative=${relative#./}
    case $relative in source-commit|source-composition.json) continue;; esac
    if ! grep -Fxq "$relative" "$stage/overlays"; then
        printf '%s  %s\n' "$expected" "$profile/$relative" | sha256sum -c --status
    fi
done < "$stage/parent-profile.sha256"
bash "$owner/tests/storage-crypto-contract.sh" "$profile/native.config"
commit=$(git -C "$owner" rev-parse HEAD)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq -Rn '[inputs]' < "$stage/overlays" > "$stage/overlays.json"
jq --arg commit "$commit" --slurpfile overlays "$stage/overlays.json" \
 '. + {source_mode:"qualified-parent-with-storage-encryption",source_commit:$commit,
 parent_copr_build:11239822,parent_srpm_sha256:"c55c77bc350c4bd39047683bfa41ba5d52d1a99e93735dfd80bb9074586a15f0",
 parent_composition:"source-composition-parent731115.json",overlays:$overlays[0],
 adaptation_patches_unchanged:true,hardware_settings_unchanged:true,physical_acceptance:false,
 storage_crypto:{filesystems:["ext4","f2fs","xfs","btrfs"],dm_crypt:true,dm_inlinecrypt:true,
 fscrypt:["ext4","f2fs"],cpu_aes:true,inline_crypto_fallback:true,
 encrypted_io_tested:false,encrypted_root_qualified:false,performance_measured:false}}' \
 "$profile/source-composition-parent731115.json" > "$profile/source-composition.json"
install -m644 "$owner/manifests/boot-payload.json" "$boot/lock.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c -)
for tree in native-profile boot-recipe; do
    case $tree in native-profile) archive=senemos-native-profile-7.3.1.tar.xz;; boot-recipe) archive=senemos-uke-boot-recipe.tar.xz;; esac
    tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner -cJf "$output/$archive" -C "$stage/unpacked" "$tree"
done
install -m644 "$boot/lock.json" "$output/boot-payload.json"
install -m644 "$owner/packaging/$spec" "$output/$spec"
sha256sum -c "$stage/retained.sha256"
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$output/$spec")" = 7.3.1-116
rpmbuild -bs --nodeps --target aarch64 --define "_sourcedir $output" --define "_srcrpmdir $output" "$output/$spec"
find "$output" -maxdepth 1 -type f ! -name '*.src.rpm' -delete
