#!/usr/bin/env bash
# COPR source worker only; retain the exact complete12204 source/preparation.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?Remote source result directory}")
revision=${2:-2}
[[ $revision =~ ^[1-9][0-9]*$ ]]
manifest=$owner/manifests/ssc-stk3bcx-als-layer-20261105.json
[[ ! -e $output || (-d $output && -z $(find "$output" -mindepth 1 -maxdepth 1 -print -quit)) ]]
bash "$owner/packaging/native/refuse-published-release.sh" uke-ssc-als-check "7.3.1-$revision"
(cd "$owner"; jq -r '.assets[],.check_inputs[]|.sha256+"  "+.path' "$manifest" | sha256sum -c --strict --quiet -)
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
curl -q -fLsS --retry 2 --max-time 600 --proto '=https' --proto-redir '=https' \
 "$(jq -er .parent.url "$manifest")" -o "$stage/parent.src.rpm"
[[ $(stat -c %s "$stage/parent.src.rpm") == "$(jq -er .parent.bytes "$manifest")" ]]
[[ $(rpm -qp --qf '%{SHA256HEADER}' "$stage/parent.src.rpm") == "$(jq -er .parent.sha256header "$manifest")" ]]
[[ $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$stage/parent.src.rpm") == senemos-uke-linux-kernel-mainline-unstable-7.3.1-12204 ]]
rpmkeys --checksig --nosignature --verbose "$stage/parent.src.rpm"
sha256sum "$stage/parent.src.rpm" > "$stage/parent.sha256"
rpm2cpio "$stage/parent.src.rpm" > "$stage/parent.cpio"
cpio -t --quiet < "$stage/parent.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/parent.cpio")
parent=$output/senemos-uke-linux-kernel-mainline-unstable.spec
printf '%s  %s\n' "$(jq -er .parent.spec_sha256 "$manifest")" "$parent" | sha256sum -c --strict -
tar -xOJf "$output/senemos-native-profile-7.3.1.tar.xz" native-profile/source-composition.json \
 | jq -e '.source_commit=="de1bdf9ab531d772a8c02847c51b01ed4ffcd42f" and
 .kernel_release=="7.3.1-12204-unstable" and .ssc_early_sample_layer==2 and
 .governor_options_layer==1 and .camera_gcc_config_layer==1 and .all_existing_features_retained' >/dev/null
find "$output" -maxdepth 1 -type f ! -name "${parent##*/}" -print0 | sort -z | xargs -0 sha256sum > "$stage/retained.sha256"
mkdir -p "$stage/addon/ssc-als-addon"
mapfile -t assets < <(jq -r '.assets[].path,.check_inputs[].path' "$manifest"; printf '%s\n' manifests/ssc-stk3bcx-als-layer-20261105.json LICENSE LICENSES/GPL-2.0-only.txt)
git -C "$owner" archive HEAD "${assets[@]}" | tar -xf - -C "$stage/addon/ssc-als-addon"
git -C "$owner" rev-parse HEAD > "$stage/addon/ssc-als-addon/source-commit"
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
 -cJf "$output/ssc-als-addon.tar.xz" -C "$stage/addon" ssc-als-addon
install -m644 "$parent" "$output/ssc-als-production-spec.txt"
cp "$stage/parent.sha256" "$output/ssc-als-source-checks.txt"
printf 'Pinned SHA256HEADER and payload digests verified; exact12204 source/composition/spec retained.\n' >> "$output/ssc-als-source-checks.txt"
[[ $(grep -c '^Source9:' "$parent") == 0 ]]
spec=$output/uke-ssc-als-check.spec
awk -v revision="$revision" '
 /^%description/ {exit}
 /^Name:/ {$0="Name: uke-ssc-als-check"}
 /^Release:/ {$0="Release: "revision"%{?dist}"}
 /^Summary:/ {$0="Summary: Uke STK3BCx front ALS vector and native SSC object check"}
 /^(Requires|Provides|Recommends|Conflicts|Obsoletes|Supplements|Suggests|Enhances)(\([^)]*\))?:/ {next}
 {print}
' "$parent" > "$spec"
cat >> "$spec" <<'SPEC'
Source9: ssc-als-addon.tar.xz
Source10: ssc-als-production-spec.txt
Source11: ssc-als-source-checks.txt

%description
Check the named Uke front-light vector on the complete12204 preparation.
Retain original source/config/DT/firmware and all hardware admission gates.
Only text receipts are packaged; no final Image, module or physical claim.

SPEC
awk '/^%prep$/ {emit=1} /^%build$/ {exit} emit {print}' "$parent" >> "$spec"
cat >> "$spec" <<'SPEC'
tar -xJf %{SOURCE9}
manifest=ssc-als-addon/manifests/ssc-stk3bcx-als-layer-20261105.json
(cd ssc-als-addon; jq -r '.assets[],.check_inputs[]|.sha256+"  "+.path' manifests/ssc-stk3bcx-als-layer-20261105.json | sha256sum -c --strict --quiet -)
cmp native-profile/src/sensors/uke-ssc-iio.c drivers/iio/common/uke-ssc/uke-ssc-iio.c
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
snapshot() { find native-profile boot-recipe -type f -print0 | sort -z | xargs -0 sha256sum; }
seal() { (cd native-profile; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS); }
cp native-profile/src/sensors/uke-ssc-iio.c "$stage/source.before"
cp native-profile/SHA256SUMS "$stage/ledger.before"
printf '\n/* Unreviewed source. */\n' >> native-profile/src/sensors/uke-ssc-iio.c
seal
snapshot > "$stage/refusal.before"
if bash ssc-als-addon/packaging/native/overlay-ssc-als731.sh native-profile boot-recipe > "$stage/refusal.log" 2>&1; then
    printf 'ALS layer admitted an unreviewed source\n' >&2; exit 1
fi
snapshot > "$stage/refusal.after"
cmp "$stage/refusal.before" "$stage/refusal.after"
install -m644 "$stage/source.before" native-profile/src/sensors/uke-ssc-iio.c
install -m644 "$stage/ledger.before" native-profile/SHA256SUMS
snapshot > "$stage/all.before"
bash ssc-als-addon/packaging/native/overlay-ssc-als731.sh native-profile boot-recipe
snapshot > "$stage/repeat.before"
bash ssc-als-addon/packaging/native/overlay-ssc-als731.sh native-profile boot-recipe
snapshot > "$stage/repeat.after"
cmp "$stage/repeat.before" "$stage/repeat.after"
while read -r digest path; do
    case "$path" in native-profile/src/sensors/uke-ssc-iio.c|boot-recipe/src/sensors/uke-ssc-iio.c|native-profile/source-composition.json|native-profile/SHA256SUMS|boot-recipe/lock.json) continue;; esac
    printf '%s  %s\n' "$digest" "$path" | sha256sum -c --strict --quiet -
done < "$stage/all.before"
install -m644 native-profile/src/sensors/uke-ssc-iio.c drivers/iio/common/uke-ssc/uke-ssc-iio.c
printf 'PASS: source refusal, exact repeat and complete unrelated-file preservation\n'

%build
set -o pipefail
bash ssc-als-addon/packaging/native/check-ssc-als731.sh "$PWD" %{_uke_out} \
 | tee %{_topdir}/ssc-als-checks.txt

%install
install -Dm644 %{_topdir}/ssc-als-checks.txt %{buildroot}%{_docdir}/%{name}/checks.txt
install -m644 %{SOURCE10} %{buildroot}%{_docdir}/%{name}/production-spec.txt
install -m644 %{SOURCE11} %{buildroot}%{_docdir}/%{name}/source-checks.txt
install -m644 ssc-als-addon/source-commit %{buildroot}%{_docdir}/%{name}/source-commit
install -m644 native-profile/source-composition.json %{buildroot}%{_docdir}/%{name}/check-view-composition.json

%check
test -s %{buildroot}%{_docdir}/%{name}/checks.txt
test ! -e %{_uke_out}/arch/arm64/boot/Image
test -z "$(find %{_uke_out} -type f -name '*.ko' -print -quit)"

%files
%license ssc-als-addon/LICENSE ssc-als-addon/LICENSES/GPL-2.0-only.txt
%{_docdir}/%{name}/*

%changelog
SPEC
day=$(date -u --date="@$epoch" '+%a %b %d %Y')
printf '* %s Uke contributors - 7.3.1-%s\n- Qualify the exact Uke STK3BCx ambient-light vector.\n' "$day" "$revision" >> "$spec"
sha256sum -c --strict --quiet "$stage/retained.sha256"
unlink "$parent"
[[ $(rpmspec --target aarch64 -q --srpm --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$spec") == uke-ssc-als-check-7.3.1-$revision* ]]
printf 'ALS source/object check prepared from complete12204; no full kernel revision or target operation\n'
