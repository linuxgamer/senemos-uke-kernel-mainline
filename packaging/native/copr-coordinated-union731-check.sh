#!/usr/bin/env bash
# COPR only: retain complete12101 and qualify the queued source/object union.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?Pass the remote source result directory}")
revision=${2:-1}
[[ $revision =~ ^[1-9][0-9]*$ ]]
manifest=manifests/coordinated-union731-20261105.json
(cd "$owner"; jq -r '.owned_inputs[]|.sha256+"  "+.path' "$manifest" | sha256sum -c --strict --quiet -)
bash "$owner/packaging/native/refuse-published-release.sh" uke-coordinated-union-check "7.3.1-$revision"
for build in 11260781 11261044 11261165 11261282 11261342 11261509; do
    [[ $(curl -q -fLsS --max-time 45 "https://copr.fedorainfracloud.org/api_3/build/$build" | jq -er .state) == succeeded ]]
done
[[ ! -e $output || (-d $output && -z $(find "$output" -mindepth 1 -maxdepth 1 -print -quit)) ]]
stage=$(mktemp -d)
cleanup()
{
    if [[ -d $stage/coordinator ]]; then git -C "$owner" worktree remove "$stage/coordinator"; fi
    find "$stage" -depth -delete
}
trap cleanup EXIT
coordinator=$(jq -er .coordinator_source.commit "$owner/$manifest")
[[ $coordinator =~ ^[a-f0-9]{40}$ ]]
git -C "$owner" cat-file -e "$coordinator^{commit}" 2>/dev/null || git -C "$owner" fetch --depth=1 origin "$coordinator"
git -C "$owner" worktree add --detach "$stage/coordinator" "$coordinator"
while IFS=$'\t' read -r relative digest; do
    printf '%s  %s\n' "$digest" "$stage/coordinator/$relative" | sha256sum -c --strict --quiet -
done < <(jq -r '.coordinator_source.assets[]|[.path,.sha256]|@tsv' "$owner/$manifest")
curl -q -fLsS --retry 2 --max-time 600 --proto '=https' --proto-redir '=https' \
 "$(jq -er .kernel_parent.url "$owner/$manifest")" -o "$stage/parent.src.rpm"
printf '%s  %s\n' "$(jq -er .kernel_parent.sha256 "$owner/$manifest")" "$stage/parent.src.rpm" | sha256sum -c --strict -
[[ $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$stage/parent.src.rpm") == senemos-uke-linux-kernel-mainline-unstable-7.3.1-12101.fc46 ]]
rpmkeys --checksig --nosignature --verbose "$stage/parent.src.rpm"
rpm2cpio "$stage/parent.src.rpm" > "$stage/parent.cpio"
cpio -t --quiet < "$stage/parent.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked" "$stage/addon"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/parent.cpio")
parent=$output/senemos-uke-linux-kernel-mainline-unstable.spec
native_archive=senemos-native-profile-7.3.1.tar.xz
boot_archive=senemos-uke-boot-recipe.tar.xz
find "$output" -maxdepth 1 -type f ! -name "${parent##*/}" ! -name "$native_archive" \
 ! -name "$boot_archive" ! -name boot-payload.json -print0 | sort -z | xargs -0 sha256sum > "$stage/retained.sha256"
for archive in "$native_archive" "$boot_archive"; do
    tar -tJf "$output/$archive" > "$stage/entries"
    awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
    tar -xJf "$output/$archive" -C "$stage/unpacked"
done
profile=$stage/unpacked/native-profile
boot=$stage/unpacked/boot-recipe
cmp "$boot/lock.json" "$output/boot-payload.json"
jq -e '.source_commit=="bba194e74ab97dcb848887fa62430c20f9d755d9" and
 .kernel_release=="7.3.1-12101-unstable" and .camcc_probe_observation_check==11260755 and
 .qualified_ssc_observation_check==11260554' "$profile/source-composition.json" >/dev/null
bash "$stage/coordinator/packaging/native/overlay-qualified-touch731.sh" "$profile" "$boot"
bash "$owner/packaging/native/overlay-o82-memory731.sh" "$profile" "$boot"
bash "$owner/tests/queued-source-layer731-contract.sh" "$owner" "$profile" "$boot" "$parent"
bash "$owner/packaging/native/overlay-o82-private-dnf731.sh" "$parent" "$profile"
install -m644 "$parent" "$output/coordinated-kernel-spec.txt"
jq --arg package "uke-coordinated-union-check-7.3.1-$revision" \
 '. + {source_check_view_only:true,source_check_package:$package}' "$profile/source-composition.json" > "$stage/composition.json"
install -m644 "$stage/composition.json" "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
install -m644 "$boot/lock.json" "$output/boot-payload.json"
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
for tree in native-profile boot-recipe; do
    archive=$native_archive
    [[ $tree != boot-recipe ]] || archive=$boot_archive
    tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
      -cJf "$output/$archive" -C "$stage/unpacked" "$tree"
done
[[ $(grep -c '^Source9:' "$parent") == 0 ]]
mkdir -p "$stage/addon/memory-addon"
while IFS=$'	' read -r commit path digest; do
    git -C "$owner" cat-file -e "$commit^{commit}" 2>/dev/null || git -C "$owner" fetch --depth=1 origin "$commit"
    mkdir -p "$stage/imports/$(dirname "$path")"
    git -C "$owner" show "$commit:$path" > "$stage/imports/$path"
    printf '%s  %s\n' "$digest" "$stage/imports/$path" | sha256sum -c --strict --quiet -
done < <(jq -r '.imported_inputs[]|[.commit,.path,.sha256]|@tsv' "$owner/$manifest")
while IFS=$'	' read -r path digest; do
    source_file=$stage/imports/$path
    [[ -f $source_file ]] || source_file=$owner/$path
    printf '%s  %s\n' "$digest" "$source_file" | sha256sum -c --strict --quiet -
    install -Dm644 "$source_file" "$stage/addon/memory-addon/$path"
done < <(jq -r '.archive_assets[]|[.path,.sha256]|@tsv' "$owner/$manifest")
install -Dm644 "$owner/$manifest" "$stage/addon/memory-addon/$manifest"
install -m644 "$owner/LICENSE" "$stage/addon/memory-addon/LICENSE"
install -Dm644 "$owner/LICENSES/GPL-2.0-only.txt" "$stage/addon/memory-addon/LICENSES/GPL-2.0-only.txt"
git -C "$owner" rev-parse HEAD > "$stage/addon/memory-addon/source-commit"
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
 -cJf "$output/o82-memory-cumulative-addon.tar.xz" -C "$stage/addon" memory-addon
spec=$output/uke-coordinated-union-check.spec
awk -v revision="$revision" '
 /^%description/ {exit}
 /^Name:/ {$0="Name: uke-coordinated-union-check"}
 /^Release:/ {$0="Release: "revision"%{?dist}"}
 /^Summary:/ {$0="Summary: Coordinated native source and combined AArch64 MSM object check"}
 /^(Requires|Provides|Recommends|Conflicts|Obsoletes|Supplements|Suggests|Enhances)(\([^)]*\))?:/ {next}
 {print}
' "$parent" > "$spec"
cat >> "$spec" <<'SPEC'
Source9: o82-memory-cumulative-addon.tar.xz
Source10: coordinated-kernel-spec.txt
BuildRequires: clang compiler-rt python3-lxml kernel-headers

%description
Qualify complete12101 plus touch, geometry, GMU, memory/v5 and DNF metadata
in one production source view and actual linked AArch64 MSM object.
Preserve all other source/config/firmware/admission fields and boot assets.
Only text receipts and licenses are packaged. No Image, linked module, boot
image, private profile or runtime executable is installed. This is not a full
kernel candidate and does not establish physical camera/color/HDR acceptance.

SPEC
awk '/^%prep$/ {emit=1} /^%build$/ {exit} emit {print}' "$parent" >> "$spec"
cat >> "$spec" <<'SPEC'
tar -xJf %{SOURCE9}

%build
set -o pipefail
bash memory-addon/packaging/native/check-coordinated-union731.sh "$PWD" %{_uke_out} \
 | tee %{_topdir}/o82-memory-cumulative-checks.txt

%install
install -Dm644 %{_topdir}/o82-memory-cumulative-checks.txt %{buildroot}%{_docdir}/%{name}/checks.txt
install -m644 %{SOURCE10} %{buildroot}%{_docdir}/%{name}/production-spec.txt
install -m644 memory-addon/source-commit %{buildroot}%{_docdir}/%{name}/source-commit
install -m644 native-profile/source-composition.json %{buildroot}%{_docdir}/%{name}/check-view-composition.json

%check
test -s %{buildroot}%{_docdir}/%{name}/checks.txt
test ! -e %{_uke_out}/arch/arm64/boot/Image

%files
%license memory-addon/LICENSE memory-addon/LICENSES/GPL-2.0-only.txt
%{_docdir}/%{name}/checks.txt
%{_docdir}/%{name}/source-commit
%{_docdir}/%{name}/production-spec.txt
%{_docdir}/%{name}/check-view-composition.json

%changelog
SPEC
day=$(date -u --date="@$epoch" '+%a %b %d %Y')
printf '* %s Uke contributors - 7.3.1-%s\n- Retain complete cumulative sources while qualifying memory/v5 MSM code.\n' \
 "$day" "$revision" >> "$spec"
sha256sum -c --strict --quiet "$stage/retained.sha256"
unlink "$parent"
[[ $(rpmspec --target aarch64 -q --srpm --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$spec") == uke-coordinated-union-check-7.3.1-$revision.fc46 ]]
printf 'Coordinated union check source prepared; no kernel revision or device state changed\n'
