#!/usr/bin/env bash
# COPR-only fixture correction; preserve the explicitly requested kernel ABI.
set -Eeuo pipefail
export LC_ALL=C
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?COPR result directory}")
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
# 1 November owner request: ABI1010, fresh RPM revision1010.1. No older ABI1010
# binary may exist; unrelated newer experimental kernels are not superseded.
seen=0
for project in uke-linux-unstable uke-linux-test uke-linux; do
 offset=0
 while ((offset < 10000)); do
  curl -fLsS --max-time 45 --get --data-urlencode ownername=mcc45tr \
   --data-urlencode "projectname=$project" --data-urlencode packagename=senemos-uke-linux-kernel-mainline \
   --data-urlencode limit=100 --data-urlencode "offset=$offset" \
   https://copr.fedorainfracloud.org/api_3/build/list > "$stage/builds.json"
  jq -e '(.items|type)=="array"' "$stage/builds.json" >/dev/null
  jq -e 'all(.items[]; if .source_package.name=="senemos-uke-linux-kernel-mainline" then
   (.source_package.version|type)=="string" else true end)' "$stage/builds.json" >/dev/null
  while IFS=$'\t' read -r id state version; do
   [[ $id == 11240670 && $state == failed && $version == 7.3.1-1010 ]]
   seen=$((seen + 1))
  done < <(jq -r '.items[]|select(.source_package.name=="senemos-uke-linux-kernel-mainline")|
   select(.source_package.version|test("^7[.]3[.]1-1010([.]|$)"))|
   [.id,.state,.source_package.version]|@tsv' "$stage/builds.json")
  count=$(jq -er '.items|length' "$stage/builds.json")
  ((count < 100)) && break
  offset=$((offset + 100))
 done
 ((offset < 10000))
done
[[ $seen == 1 ]]
curl -fLsS --max-time 45 'https://copr.fedorainfracloud.org/api_3/build-chroot?build_id=11240670&chrootname=fedora-rawhide-aarch64' > "$stage/failed-chroot.json"
jq -e '.state=="failed" and .result_url=="https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable:custom:o82-abm-20261101/fedora-rawhide-aarch64/11240670-senemos-uke-linux-kernel-mainline/"' "$stage/failed-chroot.json" >/dev/null
curl -fLsS --max-time 45 "$(jq -r .result_url "$stage/failed-chroot.json")" > "$stage/failed-index.html"
! grep -Eq 'href="[^" ]+[.](aarch64|noarch)[.]rpm"' "$stage/failed-index.html"
curl -fLsS --retry 2 --proto '=https' --proto-redir '=https' \
 https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable:custom:o82-abm-20261101/srpm-builds/11240670/senemos-uke-linux-kernel-mainline-7.3.1-1010.src.rpm -o "$stage/base.src.rpm"
printf '%s  %s\n' 834165e195638d8b975a57a5af3b9a4087a90b2f38a698822ad45bac5aa6386d "$stage/base.src.rpm" | sha256sum -c -
[[ $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$stage/base.src.rpm") == senemos-uke-linux-kernel-mainline-7.3.1-1010 ]]
rpm2cpio "$stage/base.src.rpm" > "$stage/base.cpio"
cpio -t --quiet < "$stage/base.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/base.cpio")
spec=$output/senemos-uke-linux-kernel-mainline.spec
find "$output" -maxdepth 1 -type f ! -name "${spec##*/}" ! -name senemos-native-profile-7.3.1.tar.xz \
 -print0 | sort -z | xargs -0 sha256sum > "$stage/retained.sha256"
archive=senemos-native-profile-7.3.1.tar.xz
tar -tJf "$output/$archive" > "$stage/archive.entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/archive.entries"
tar -xJf "$output/$archive" -C "$stage/unpacked"
profile=$stage/unpacked/native-profile
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS)
cp "$profile/source-composition.json" "$profile/source-composition-before1010-final.json"
cp "$profile/tests/o82-panel-contract.sh" "$profile/tests/o82-panel-contract-before1010.sh"
[[ $(grep -Fc 'MIPI_DSI_DCS_SHORT_WRITE_PARAM=0x15,' "$profile/tests/o82-panel-contract.sh") == 1 ]]
sed '/MIPI_DSI_DCS_SHORT_WRITE_PARAM=0x15,/d' "$profile/tests/o82-panel-contract.sh" > "$stage/expected-test.sh"
cmp "$stage/expected-test.sh" "$owner/tests/o82-panel-contract.sh"
install -m644 "$owner/tests/o82-panel-contract.sh" "$profile/tests/o82-panel-contract.sh"
commit=$(git -C "$owner" rev-parse HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq --arg commit "$commit" '. + {source_commit:$commit,source_mode:"retained1010-production-with-panel-fixture-fix",parent_copr_build:11240670,parent_srpm_sha256:"834165e195638d8b975a57a5af3b9a4087a90b2f38a698822ad45bac5aa6386d",parent_composition:"source-composition-before1010-final.json",kernel_release:"7.3.1-1010",rpm_revision:"1010.1",production_source_unchanged:true,physical_acceptance:false}' "$profile/source-composition-before1010-final.json" > "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
tar --sort=name --mtime=@1793491200 --owner=0 --group=0 --numeric-owner -cJf "$output/senemos-native-profile-7.3.1.tar.xz" -C "$stage/unpacked" native-profile
[[ $(grep -Fxc '%global senemos_build_release 1010' "$spec") == 1 ]]
[[ $(grep -Fxc 'Release: %{senemos_build_release}%{?dist}' "$spec") == 1 ]]
sed -i 's/^Release: %{senemos_build_release}%{?dist}$/Release: 1010.1%{?dist}/' "$spec"
[[ $(grep -Fc 'CC=clang bash native-profile/tests/o82-panel-contract.sh ' "$spec") == 1 ]]
awk '
 /^CC=clang bash native-profile\/tests\/o82-panel-contract.sh / {
  print "if CC=clang bash native-profile/tests/o82-panel-contract-before1010.sh native-profile/src/display/panel-xiaomi-o82.c native-profile/src/display/o82-data.h \"$PWD\" > %{_uke_out}/o82-before1010-negative.log 2>&1; then cat %{_uke_out}/o82-before1010-negative.log; exit 1; fi"
  print "grep -Fq \"redefinition of enumerator '\''MIPI_DSI_DCS_SHORT_WRITE_PARAM'\''\" %{_uke_out}/o82-before1010-negative.log"
  print "echo '\''Original1010 fixture reproduced the duplicate upstream enum; corrected fixture follows.'\''"
 }
 {print}' "$spec" > "$stage/next.spec"
mv "$stage/next.spec" "$spec"
sha256sum -c "$stage/retained.sha256"
[[ $(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec") == 7.3.1-1010.1 ]]
[[ $(grep -Fxc '%global krel %{version}-%{senemos_build_release}' "$spec") == 1 ]]
