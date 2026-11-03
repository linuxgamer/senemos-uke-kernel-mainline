#!/usr/bin/env bash
# COPR-only candidate: retain accepted release54 inputs and overlay reset support.
set -Eeuo pipefail
export LC_ALL=C
[[ -n ${COPR_RESULTDIR:-} ]]
owner=$(cd -- "$(dirname -- "$0")/../..";pwd)
output=$(realpath -m "${1:?COPR result directory}")
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
make -C "$owner" validate
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
curl --fail --location --silent --show-error --retry 3 --proto '=https' --proto-redir '=https' \
 https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/11228863/senemos-uke-linux-kernel-mainline-7.3.0-54.src.rpm -o "$stage/parent.src.rpm"
printf '%s  %s\n' 615b362bd44b15ec267c16532e986629df422966658769f6bb715004bfa7c1b0 "$stage/parent.src.rpm" | sha256sum -c -
rpm2cpio "$stage/parent.src.rpm" > "$stage/parent.cpio"
cpio -t --quiet < "$stage/parent.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked"
(cd "$output";cpio -idm --quiet --no-absolute-filenames < "$stage/parent.cpio")
spec=senemos-uke-linux-kernel-mainline.spec
find "$output" -maxdepth 1 -type f ! -name "$spec" ! -name 'senemos-native-profile-*' \
 ! -name senemos-uke-boot-recipe.tar.xz ! -name boot-payload.json -print0 | sort -z | xargs -0 sha256sum > "$stage/unchanged.sha256"
tar -tJf "$output/senemos-native-profile-7.3.0.tar.xz" | awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}'
tar -xJf "$output/senemos-native-profile-7.3.0.tar.xz" -C "$stage/unpacked"
profile=$stage/unpacked/native-profile
(cd "$profile";sha256sum --check --strict --quiet SHA256SUMS)
cp "$profile/source-composition.json" "$profile/source-composition-parent54.json"
overlays=(src/boot/prepare-abl-source.sh src/boot/uke-root-selector.h src/boot/build-payload.sh \
 src/boot/check-root-capability.sh src/boot/dracut/module-setup.sh src/boot/dracut/uke-initrd-deadline.service \
 patches/boot/0045-gunyah-arm-bounded-boot-watchdog.patch tests/gunyah-boot-watchdog-contract.sh \
 tests/root-selector-contract.cpp tests/root-selector-note-contract.sh tests/mainline-package-contract.sh)
for path in "${overlays[@]}";do install -Dm644 "$owner/$path" "$profile/$path";done
install -m644 "$owner/packaging/native/native.config" "$profile/native.config"
commit=$(git -C "$owner" rev-parse HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq -n --arg commit "$commit" --args '{schema_version:1,source_mode:"pinned-parent-with-explicit-overlay",source_commit:$commit,parent_copr_build:11228863,parent_srpm_sha256:"615b362bd44b15ec267c16532e986629df422966658769f6bb715004bfa7c1b0",parent_composition:"source-composition-parent54.json",overlays:$ARGS.positional,source_validation:"COPR source/native fixtures and final Image note checks",physical_acceptance:false}' \
 "${overlays[@]}" native.config > "$profile/source-composition.json"
(cd "$profile";find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
tar --sort=name --mtime=@1791725270 --owner=0 --group=0 --numeric-owner -cJf "$output/senemos-native-profile-7.3.0.tar.xz" -C "$stage/unpacked" native-profile
bash "$owner/scripts/stage-boot-sources.sh" "$output"
install -m644 "$owner/packaging/$spec" "$output/$spec"
sha256sum -c "$stage/unchanged.sha256"
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$output/$spec")" = 7.3.0-61
