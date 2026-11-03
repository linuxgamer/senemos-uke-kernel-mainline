#!/usr/bin/env bash
# Export the pinned project source; never execute an archived vendor recipe.
set -Eeuo pipefail
[[ $# == 1 && -d $1 ]] || exit 2
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
destination=$(realpath "$1") lock=$root/manifests/touch-runtime.json
jq -e '.schema==1 and .private_inputs==false' "$lock" >/dev/null
commit=$(jq -er .owner_commit "$lock")
[[ $commit =~ ^[a-f0-9]{40}$ ]]
cache=$root/referances/touch-runtime
mkdir -p "$cache"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
archive=$cache/hardware-support-$commit.tar.gz
if [[ ! -s $archive ]]; then
    curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
        --connect-timeout 20 --max-time 240 \
        "https://github.com/MCC45TR/uke-linux-hardware-support/archive/$commit.tar.gz" -o "$work/owner.tar.gz"
    printf '%s  %s\n' "$(jq -er .owner_archive_sha256 "$lock")" "$work/owner.tar.gz" | sha256sum -c -
    mv "$work/owner.tar.gz" "$archive"
fi
printf '%s  %s\n' "$(jq -er .owner_archive_sha256 "$lock")" "$archive" | sha256sum -c -
prefix=uke-linux-hardware-support-$commit
tar -tzf "$archive" | awk -v p="$prefix/" 'index($0,p)!=1 || /(^|\/)\.\.($|\/)/ {bad=1} END{exit bad}'
tar -tvzf "$archive" | awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d"{bad=1} END{exit bad}'
tar -xzf "$archive" -C "$work"
inputs=$work/$prefix/uke-sensors/manifests/touch-runtime-source.json
rpm_source=$cache/uke-touchscreen-source.src.rpm
if [[ ! -s $rpm_source ]]; then
    url=$(jq -er .url "$inputs")
    [[ $url == https://github.com/MCC45TR/uke-linux-hardware-support/releases/download/copr-migration-archive-20261020/uke-touchscreen-0.1.0-13.fc46.src.rpm ]]
    curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
        --connect-timeout 20 --max-time 240 "$url" -o "$work/touch.src.rpm"
    printf '%s  %s\n' "$(jq -er .sha256 "$inputs")" "$work/touch.src.rpm" | sha256sum -c -
    mv "$work/touch.src.rpm" "$rpm_source"
fi
bash "$work/$prefix/uke-sensors/src/prepare-touch-runtime.sh" "$rpm_source" "$work/touch-runtime" "$commit"
install -m644 "$work/$prefix/LICENSE" "$work/touch-runtime/capture/LICENSE.MIT"
(cd "$work/touch-runtime"; find legacy capture -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > SOURCE-SHA256SUMS)
cp "$lock" "$work/touch-runtime/kernel-source-lock.json"
tar --sort=name --mtime="@$(jq -er .source_date_epoch "$lock")" --owner=0 --group=0 --numeric-owner \
    -cJf "$work/senemos-uke-touch-runtime-1.tar.xz" -C "$work" touch-runtime
install -m644 "$work/senemos-uke-touch-runtime-1.tar.xz" "$destination/"
