#!/bin/bash
set -Eeuo pipefail
export LC_ALL=C
[[ $(rpm --eval '%{_host_cpu}') == aarch64 ]]
grep -Eq '^VERSION="?(Rawhide|[0-9]+ \(Rawhide( Prerelease)?\))"?$|^VERSION_ID="?rawhide"?$' /etc/os-release
curl --fail --location --retry 3 --proto '=https' --proto-redir '=https' 'https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-test/srpm-builds/11222548/senemos-uke-linux-kernel-mainline-7.3.0-50.fc46.src.rpm' -o base.src.rpm
printf '%s\n' 'e76815db7f6d88758e0709574f69137467005d4d331a31e8eeaa7c4ed796ac44  base.src.rpm' | sha256sum -c -
rpm2cpio base.src.rpm > base.cpio
cpio -t --quiet < base.cpio > source-files
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' source-files
mkdir result work
(cd result; cpio -idm --quiet --no-absolute-filenames < ../base.cpio)
tar -xJf result/senemos-native-profile-7.3.0.tar.xz -C work
test "$(cat work/native-profile/source-commit)" = 8cbe0435f05c8a26dd891bd842ec8533a1504421
curl --fail --location --retry 3 --proto '=https' --proto-redir '=https' 'https://raw.githubusercontent.com/MCC45TR/senemos-uke-kernel-mainline/b81f2cc666ffc3fcae9cf87c37bbe573d369dc83/referances/copr/youtube51-20261029/source-overlay.tar.xz' -o overlay.tar.xz
printf '%s\n' '93876a3d8c047e396c9cf35a472eab3047ece61cbb61e9d7cc68427232e15530  overlay.tar.xz' | sha256sum -c -
tar -tJf overlay.tar.xz > overlay-files
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' overlay-files
tar -xJf overlay.tar.xz -C work
(cd work/native-profile; while IFS=$'\t' read -r path hash; do test "$(sha256sum "$path" | cut -d' ' -f1)" = "$hash"; done < <(jq -r '.patches[]|[.path,.sha256]|@tsv' manifests/video-linux73-candidate-20261025.json))
(cd work/native-profile; find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > SHA256SUMS)
tar --sort=name --mtime=@1793232000 --owner=0 --group=0 --numeric-owner -cJf result/senemos-native-profile-7.3.0.tar.xz -C work native-profile
install -m644 work/senemos-uke-linux-kernel-mainline.spec result/
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' result/senemos-uke-linux-kernel-mainline.spec)" = 7.3.0-51
