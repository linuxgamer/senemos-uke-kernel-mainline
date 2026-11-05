#!/usr/bin/env bash
# COPR source worker only: preserve the complete frozen12203 preparation.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?Remote source result directory}")
revision=${2:-1}
[[ $revision =~ ^[1-9][0-9]*$ ]]
manifest=$owner/manifests/ssc-early-layer-v2-20261105.json
[[ ! -e $output || (-d $output && -z $(find "$output" -mindepth 1 -maxdepth 1 -print -quit)) ]]
bash "$owner/packaging/native/refuse-published-release.sh" uke-ssc-early-check "7.3.1-$revision"
(cd "$owner"; jq -r '.assets[],.check_inputs[]|.sha256+"  "+.path' "$manifest" | sha256sum -c --strict --quiet -)
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
curl -q -fLsS --retry 2 --max-time 600 --proto '=https' --proto-redir '=https' \
    "$(jq -er .parent.url "$manifest")" -o "$stage/parent.src.rpm"
printf '%s  %s\n' "$(jq -er .parent.sha256 "$manifest")" "$stage/parent.src.rpm" | sha256sum -c --strict -
[[ $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$stage/parent.src.rpm") == senemos-uke-linux-kernel-mainline-unstable-7.3.1-12203* ]]
rpmkeys --checksig --nosignature --verbose "$stage/parent.src.rpm"
rpm2cpio "$stage/parent.src.rpm" > "$stage/parent.cpio"
cpio -t --quiet < "$stage/parent.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/parent.cpio")
parent=$output/senemos-uke-linux-kernel-mainline-unstable.spec
native_archive=senemos-native-profile-7.3.1.tar.xz
boot_archive=senemos-uke-boot-recipe.tar.xz
find "$output" -maxdepth 1 -type f ! -name "${parent##*/}" ! -name "$native_archive" \
    ! -name "$boot_archive" ! -name boot-payload.json -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > "$stage/retained.sha256"
for archive in "$native_archive" "$boot_archive"; do
    tar -tJf "$output/$archive" > "$stage/entries"
    awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
    tar -xJf "$output/$archive" -C "$stage/unpacked"
done
profile=$stage/unpacked/native-profile
boot=$stage/unpacked/boot-recipe
cmp "$boot/lock.json" "$output/boot-payload.json"
jq -e '.source_commit=="45d8355e366e6b75e43f441ca99b517302adf522" and
 .kernel_release=="7.3.1-12203-unstable" and .speaker_legacy_fixture_layer_commit=="f05c32a879b9c56abe3531365f95b85684af4510"' \
 "$profile/source-composition.json" >/dev/null
addon=$stage/addon/ssc-early-addon
mkdir -p "$addon/original/src/sensors" "$addon/original/tests"
for path in src/sensors/uke-ssc-iio.c src/sensors/uke-ssc-protocol.c src/sensors/uke-ssc-protocol.h \
    tests/ssc-native-host.h tests/ssc-native-contract.sh; do
    install -m644 "$profile/$path" "$addon/original/$path"
done
# The negative control retains the exact old production/script but uses the
# same new behavioral assertions as the corrected consumer.
install -m644 "$owner/tests/ssc-native-contract.c" "$addon/original/tests/ssc-native-contract.c"
superseded=$(jq -er .superseded.source_commit "$manifest")
[[ $superseded == 0dcfd5bcd42867dbf15853fa20e9e64b18ce136e ]]
git -C "$owner" cat-file -e "$superseded^{commit}" 2>/dev/null || git -C "$owner" fetch --depth=1 origin "$superseded"
mkdir -p "$addon/v1/src/sensors" "$addon/v1/tests"
for path in src/sensors/uke-ssc-protocol.c src/sensors/uke-ssc-protocol.h tests/ssc-native-host.h; do
    install -m644 "$profile/$path" "$addon/v1/$path"
done
for path in src/sensors/uke-ssc-iio.c tests/ssc-native-contract.sh; do
    git -C "$owner" show "$superseded:$path" > "$addon/v1/$path"
done
install -m644 "$owner/tests/ssc-native-contract.c" "$addon/v1/tests/ssc-native-contract.c"
snapshot()
{
    for tree in "$profile" "$boot"; do
        (cd "$tree"; find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
    done
}
seal() { (cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS); }
cp "$profile/src/sensors/uke-ssc-iio.c" "$stage/source.before"
cp "$profile/SHA256SUMS" "$stage/ledger.before"
printf '\n/* Unreviewed source. */\n' >> "$profile/src/sensors/uke-ssc-iio.c"
seal
snapshot > "$stage/refusal.before"
if bash "$owner/packaging/native/overlay-ssc-early731.sh" "$profile" "$boot" > "$stage/refusal.log" 2>&1; then
    printf 'Early-indication layer admitted an unreviewed source preimage\n' >&2; exit 1
fi
snapshot > "$stage/refusal.after"
cmp "$stage/refusal.before" "$stage/refusal.after"
install -m644 "$stage/source.before" "$profile/src/sensors/uke-ssc-iio.c"
install -m644 "$stage/ledger.before" "$profile/SHA256SUMS"
bash "$owner/packaging/native/overlay-ssc-early731.sh" "$profile" "$boot"
snapshot > "$stage/repeat.before"
bash "$owner/packaging/native/overlay-ssc-early731.sh" "$profile" "$boot"
snapshot > "$stage/repeat.after"
cmp "$stage/repeat.before" "$stage/repeat.after"
cp "$profile/source-composition.json" "$stage/composition.before"
jq '.ssc_early_sample_requires_ack=false' "$stage/composition.before" > "$profile/source-composition.json"
seal
snapshot > "$stage/refusal.before"
if bash "$owner/packaging/native/overlay-ssc-early731.sh" "$profile" "$boot" > "$stage/refusal.log" 2>&1; then
    printf 'Early-indication layer admitted false acknowledgement metadata\n' >&2; exit 1
fi
snapshot > "$stage/refusal.after"
cmp "$stage/refusal.before" "$stage/refusal.after"
install -m644 "$stage/composition.before" "$profile/source-composition.json"
seal
printf '%s\n' 'PASS: both refusals preserve every file; exact repeated overlay; original config/DT/firmware/spec retained' > "$output/ssc-early-source-checks.txt"
install -m644 "$boot/lock.json" "$output/boot-payload.json"
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
for tree in native-profile boot-recipe; do
    archive=$native_archive
    [[ $tree != boot-recipe ]] || archive=$boot_archive
    tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
        -cJf "$output/$archive" -C "$stage/unpacked" "$tree"
done
mapfile -t assets < <(jq -r '.assets[].path,.check_inputs[].path' "$manifest"; printf '%s\n' manifests/ssc-early-layer-v2-20261105.json LICENSE LICENSES/GPL-2.0-only.txt)
git -C "$owner" archive HEAD "${assets[@]}" | tar -xf - -C "$addon"
git -C "$owner" rev-parse HEAD > "$addon/source-commit"
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
    -cJf "$output/ssc-early-addon.tar.xz" -C "$stage/addon" ssc-early-addon
install -m644 "$parent" "$output/ssc-early-production-spec.txt"
[[ $(grep -c '^Source9:' "$parent") == 0 ]]
spec=$output/uke-ssc-early-check.spec
awk -v revision="$revision" '
 /^%description/ {exit}
 /^Name:/ {$0="Name: uke-ssc-early-check"}
 /^Release:/ {$0="Release: "revision"%{?dist}"}
 /^Summary:/ {$0="Summary: SSC indication ordering and cumulative AArch64 object check"}
 /^(Requires|Provides|Recommends|Conflicts|Obsoletes|Supplements|Suggests|Enhances)(\([^)]*\))?:/ {next}
 {print}
' "$parent" > "$spec"
cat >> "$spec" <<'SPEC'
Source9: ssc-early-addon.tar.xz
Source10: ssc-early-production-spec.txt
Source11: ssc-early-source-checks.txt

%description
Check bounded indication staging over the complete frozen12203 source.
Retain the original preparation and all hardware admission gates. Package text
receipts only; no Image, final module, target installation or physical claim.

SPEC
awk '/^%prep$/ {emit=1} /^%build$/ {exit} emit {print}' "$parent" >> "$spec"
cat >> "$spec" <<'SPEC'
tar -xJf %{SOURCE9}

%build
set -o pipefail
bash ssc-early-addon/packaging/native/check-ssc-early731.sh "$PWD" %{_uke_out} \
    | tee %{_topdir}/ssc-early-checks.txt

%install
install -Dm644 %{_topdir}/ssc-early-checks.txt %{buildroot}%{_docdir}/%{name}/checks.txt
install -m644 %{SOURCE10} %{buildroot}%{_docdir}/%{name}/production-spec.txt
install -m644 %{SOURCE11} %{buildroot}%{_docdir}/%{name}/source-checks.txt
install -m644 ssc-early-addon/source-commit %{buildroot}%{_docdir}/%{name}/source-commit
install -m644 native-profile/source-composition.json %{buildroot}%{_docdir}/%{name}/check-view-composition.json

%check
test -s %{buildroot}%{_docdir}/%{name}/checks.txt
test ! -e %{_uke_out}/arch/arm64/boot/Image
test -z "$(find %{_uke_out} -type f -name '*.ko' -print -quit)"

%files
%license ssc-early-addon/LICENSE ssc-early-addon/LICENSES/GPL-2.0-only.txt
%{_docdir}/%{name}/*

%changelog
SPEC
day=$(date -u --date="@$epoch" '+%a %b %d %Y')
printf '* %s Uke contributors - 7.3.1-%s\n- Preserve SSC samples that precede their enable acknowledgement.\n' "$day" "$revision" >> "$spec"
sha256sum -c --strict --quiet "$stage/retained.sha256"
unlink "$parent"
[[ $(rpmspec --target aarch64 -q --srpm --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$spec") == uke-ssc-early-check-7.3.1-$revision* ]]
printf '%s\n' 'SSC ordering check prepared from complete12203; no full kernel revision or target operation'
