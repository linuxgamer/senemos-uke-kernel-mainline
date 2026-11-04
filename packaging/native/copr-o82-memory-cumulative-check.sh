#!/usr/bin/env bash
# COPR only: preserve complete12101 plus qualified touch/geometry and add memory.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?Pass the remote source result directory}")
revision=${2:-1}
[[ $revision =~ ^[1-9][0-9]*$ ]]
manifest=manifests/o82-memory-cumulative-source-20261105.json
(cd "$owner"; jq -r '.archive_assets[]|.sha256+"  "+.path' "$manifest" | sha256sum -c --strict --quiet -)
bash "$owner/packaging/native/refuse-published-release.sh" uke-o82-memory-cumulative-check "7.3.1-$revision"
for build in 11260781 11261044 11261165 11261174; do
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
(cd "$profile"; find . -type f ! -name SHA256SUMS ! -name source-composition.json -print0 | sort -z | xargs -0 sha256sum) > "$stage/before-geometry.sha256"
geometry=(src/camera/sensors/0005-ov08d10-selection731.patch
 tests/camera-geometry731-contract.sh tests/camera-geometry731-object.sh
 tests/fixtures/camera-geometry731.c docs/OV08D10-GEOMETRY731.md
 manifests/camera-geometry731-20261105.json)
for relative in "${geometry[@]}"; do
    test ! -e "$profile/$relative"
    install -Dm644 "$stage/coordinator/$relative" "$profile/$relative"
done
jq '. + {camera_geometry_source:"9398700a6375a309f572d588a9e448cdbc4b0736",
 camera_geometry_check:11261165,camera_geometry_three_argument_pad_api:true,
 camera_geometry_private_mutex_and_per_file_try:true,camera_geometry_physical_acceptance:false}' \
 "$profile/source-composition.json" > "$stage/composition.json"
install -m644 "$stage/composition.json" "$profile/source-composition.json"
(cd "$profile"; sha256sum -c --strict --quiet "$stage/before-geometry.sha256")
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
bash "$owner/tests/o82-memory-layer-contract.sh" "$owner" "$profile" "$boot"
jq --arg package "uke-o82-memory-cumulative-check-7.3.1-$revision" \
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
mapfile -t assets < <(jq -r '.archive_assets[].path' "$owner/$manifest")
git -C "$owner" archive --prefix=memory-addon/ HEAD "${assets[@]}" "$manifest" LICENSE LICENSES/GPL-2.0-only.txt \
 | tar -xf - -C "$stage/addon"
while IFS=$'\t' read -r relative digest; do
    install -Dm644 "$stage/coordinator/$relative" "$stage/addon/memory-addon/$relative"
done < <(jq -r '.coordinator_source.assets[]|[.path,.sha256]|@tsv' "$owner/$manifest")
git -C "$owner" rev-parse HEAD > "$stage/addon/memory-addon/source-commit"
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
 -cJf "$output/o82-memory-cumulative-addon.tar.xz" -C "$stage/addon" memory-addon
spec=$output/uke-o82-memory-cumulative-check.spec
awk -v revision="$revision" '
 /^%description/ {exit}
 /^Name:/ {$0="Name: uke-o82-memory-cumulative-check"}
 /^Release:/ {$0="Release: "revision"%{?dist}"}
 /^Summary:/ {$0="Summary: Cumulative native O82 memory and v5 MSM source check"}
 /^(Requires|Provides|Recommends|Conflicts|Obsoletes|Supplements|Suggests|Enhances)(\([^)]*\))?:/ {next}
 {print}
' "$parent" > "$spec"
cat >> "$spec" <<'SPEC'
Source9: o82-memory-cumulative-addon.tar.xz
BuildRequires: clang compiler-rt python3-lxml

%description
Qualify source layering and an actual AArch64 MSM object on the complete12101
baseline plus qualified touch, front geometry and native memory/v5 changes.
Preserve all other source/config/firmware/admission fields and boot assets.
Only text receipts and licenses are packaged. No Image, linked module, boot
image, private profile or runtime executable is installed. This is not a full
kernel candidate and does not establish physical camera/color/HDR acceptance.

SPEC
awk '/^%prep$/ {emit=1} /^%build$/ {exit} emit {print}' "$parent" >> "$spec"
cat >> "$spec" <<'SPEC'
tar -xJf %{SOURCE9}
printf '%s  %s\n' 96aad491915796d54e2a8cd20c90a9a8c4e58515c64f7ad4d5faae39caa4d31c drivers/media/i2c/ov08d10.c | sha256sum -c --strict -
git apply --check native-profile/src/camera/sensors/0005-ov08d10-selection731.patch
git apply native-profile/src/camera/sensors/0005-ov08d10-selection731.patch
printf '%s  %s\n' df7ce54741d6a08c09ff607b86ce33c2057bb05c52b4d1a21d98b5be3395700e drivers/media/i2c/ov08d10.c | sha256sum -c --strict -

%build
set -o pipefail
bash memory-addon/packaging/native/check-o82-memory-cumulative.sh "$PWD" %{_uke_out} \
 | tee %{_topdir}/o82-memory-cumulative-checks.txt

%install
install -Dm644 %{_topdir}/o82-memory-cumulative-checks.txt %{buildroot}%{_docdir}/%{name}/checks.txt
install -m644 memory-addon/source-commit %{buildroot}%{_docdir}/%{name}/source-commit
install -m644 native-profile/source-composition.json %{buildroot}%{_docdir}/%{name}/check-view-composition.json

%check
test -s %{buildroot}%{_docdir}/%{name}/checks.txt
test ! -e %{_uke_out}/arch/arm64/boot/Image

%files
%license memory-addon/LICENSE memory-addon/LICENSES/GPL-2.0-only.txt
%{_docdir}/%{name}/checks.txt
%{_docdir}/%{name}/source-commit
%{_docdir}/%{name}/check-view-composition.json

%changelog
SPEC
day=$(date -u --date="@$epoch" '+%a %b %d %Y')
printf '* %s Uke contributors - 7.3.1-%s\n- Retain complete cumulative sources while qualifying memory/v5 MSM code.\n' \
 "$day" "$revision" >> "$spec"
sha256sum -c --strict --quiet "$stage/retained.sha256"
unlink "$parent"
[[ $(rpmspec --target aarch64 -q --srpm --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$spec") == uke-o82-memory-cumulative-check-7.3.1-$revision.fc46 ]]
printf 'Cumulative memory/v5 check source prepared; no kernel revision or device state changed\n'
