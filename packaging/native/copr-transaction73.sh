#!/usr/bin/env bash
# COPR-only: retain release60 sources and require final DNF boot staging.
set -Eeuo pipefail
export LC_ALL=C
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline 7.3.0-73
output=$(realpath -m "${1:?COPR result directory}")
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
make -C "$owner" validate
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
curl --fail --location --silent --show-error --retry 3 --proto '=https' --proto-redir '=https' \
 https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/11230581/senemos-uke-linux-kernel-mainline-7.3.0-60.src.rpm -o "$stage/base.src.rpm"
printf '%s  %s\n' b6352bcfd676eaeaa60c92577a3a53c5cb870a2310fb9dc8bbb58548a7987394 "$stage/base.src.rpm" | sha256sum -c -
rpm2cpio "$stage/base.src.rpm" > "$stage/base.cpio"
cpio -t --quiet < "$stage/base.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/base.cpio")
spec=senemos-uke-linux-kernel-mainline.spec
printf '%s  %s\n' ecf44522bbfd183da3751aa48701c264fe4e51266caeb4f44c688a13175fc7f0 "$output/$spec" | sha256sum -c -
find "$output" -maxdepth 1 -type f ! -name "$spec" -print0 | sort -z | xargs -0 sha256sum > "$stage/unchanged.sha256"
install -m644 "$owner/packaging/$spec" "$output/$spec"
sha256sum -c "$stage/unchanged.sha256"
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$output/$spec")" = 7.3.0-73
printf 'Release73 packaging source: %s; all non-spec release60 sources unchanged\n' "$(git -C "$owner" rev-parse HEAD)"
