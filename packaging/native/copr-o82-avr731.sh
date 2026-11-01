#!/usr/bin/env bash
# COPR-only: retain installed release116 power/startup fixes and the O82 floor.
set -Eeuo pipefail
export LC_ALL=C
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?COPR result directory}")
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline 7.3.1-118
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
spec=senemos-uke-linux-kernel-mainline.spec
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$output/$spec")" = 7.3.1-116
find "$output" -maxdepth 1 -type f ! -name "$spec" ! -name senemos-native-profile-7.3.1.tar.xz \
 ! -name senemos-uke-boot-recipe.tar.xz ! -name boot-payload.json -print0 | sort -z | xargs -0 sha256sum > "$stage/retained.sha256"
for archive in senemos-native-profile-7.3.1.tar.xz senemos-uke-boot-recipe.tar.xz; do
    tar -tJf "$output/$archive" > "$stage/archive.entries"
    awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/archive.entries"
    tar -xJf "$output/$archive" -C "$stage/unpacked"
done
profile=$stage/unpacked/native-profile
boot=$stage/unpacked/boot-recipe
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS)
grep -Fx d9d48e916070c95d19518dda4aa8bcf11ed3d2b4 "$profile/source-commit"
cp "$profile/SHA256SUMS" "$stage/parent-profile.sha256"
cp "$profile/source-composition.json" "$profile/source-composition-parent731116.json"
overlays=(
 packaging/native/prepare.sh packaging/native/README.md
 src/display/panel-xiaomi-o82.c patches/display/0069-o82-requested-vrr-floor.patch
 tests/o82-panel-contract.sh tests/o82-vrr-floor-contract.sh
)
: > "$stage/overlays"
for relative in "${overlays[@]}"; do
    destination=$relative
    case $relative in packaging/native/*) destination=${relative##*/};; esac
    install -Dm644 "$owner/$relative" "$profile/$destination"
    printf '%s\n' "$destination" >> "$stage/overlays"
    if jq -e --arg path "$relative" '.source_assets[]|select(.path==$path)' "$boot/lock.json" >/dev/null; then
        install -Dm644 "$owner/$relative" "$boot/$relative"
        hash=$(sha256sum "$boot/$relative"); hash=${hash%% *}
        jq --arg path "$relative" --arg hash "$hash" \
            '(.source_assets[]|select(.path==$path).sha256)=$hash' \
            "$boot/lock.json" > "$boot/lock.json.new"
        mv "$boot/lock.json.new" "$boot/lock.json"
    fi
done
while read -r expected relative; do
    relative=${relative#./}
    case $relative in source-commit|source-composition.json) continue;; esac
    if ! grep -Fxq -- "$relative" "$stage/overlays"; then
        printf '%s  %s\n' "$expected" "$profile/$relative" | sha256sum -c -
    fi
done < "$stage/parent-profile.sha256"
commit=$(git -C "$owner" rev-parse HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq -Rn '[inputs]' < "$stage/overlays" > "$stage/overlays.json"
jq --arg commit "$commit" --slurpfile overlays "$stage/overlays.json" \
 'del(.hardware_settings_unchanged) + {source_mode:"retained-parent116-with-o82-restoration-and-requested-avr-floor",source_commit:$commit,parent_copr_build:11239905,parent_srpm_sha256:"e376800a58f3d1b91e89b5f88b678da950e74157035db7944edbf306cc7f822c",parent_composition:"source-composition-parent731116.json",adaptation_patches_unchanged:true,startup_fixes_retained:true,power_profile_retained:true,overlays:$overlays[0],vrr_opt_in_floor_hz:30,vrr_ceiling_hz:144,vrr_default_enabled:false,electrical_limits_unchanged:true,amplifier_gain_changed:false,physical_acceptance:false}' \
 "$profile/source-composition-parent731116.json" > "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c -)
for tree in native-profile boot-recipe; do
    case $tree in
        native-profile) archive=senemos-native-profile-7.3.1.tar.xz;;
        boot-recipe) archive=senemos-uke-boot-recipe.tar.xz;;
    esac
    tar --sort=name --mtime=@1793491200 --owner=0 --group=0 --numeric-owner -cJf "$output/$archive" -C "$stage/unpacked" "$tree"
done
install -m644 "$boot/lock.json" "$output/boot-payload.json"
install -m644 "$owner/packaging/$spec" "$output/$spec"
sha256sum -c "$stage/retained.sha256"
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$output/$spec")" = 7.3.1-118
