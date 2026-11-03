#!/usr/bin/env bash
# COPR source worker only. Rebuild the exact release-51 inputs with corrected packaging.
set -Eeuo pipefail
export LC_ALL=C
owner=$(cd -- "$(dirname -- "$0")/../.."; pwd)
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline 7.3.0-52
output=$(realpath -m "${1:?COPR result directory}")
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
curl --fail --location --silent --show-error --retry 3 --proto '=https' --proto-redir '=https' \
    https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/11228360/senemos-uke-linux-kernel-mainline-7.3.0-51.src.rpm \
    -o "$stage/base.src.rpm"
printf '%s  %s\n' 93b1a04660b5bc208031900985649a10c433ef5302f98e10cc883732fd001d28 "$stage/base.src.rpm" | sha256sum -c -
rpm2cpio "$stage/base.src.rpm" > "$stage/base.cpio"
cpio -t --quiet < "$stage/base.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/base.cpio")
spec=senemos-uke-linux-kernel-mainline.spec
printf '%s  %s\n' b22c6a8995a5a97f2b703aa6fe726b6e24784670a9bd20693a8b6baea2ed2de8 "$output/$spec" | sha256sum -c -
find "$output" -maxdepth 1 -type f ! -name "$spec" -print0 | sort -z | xargs -0 sha256sum > "$stage/unchanged.sha256"
install -m644 "$owner/packaging/$spec" "$output/$spec"
sha256sum -c "$stage/unchanged.sha256"
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$output/$spec")" = 7.3.0-52
