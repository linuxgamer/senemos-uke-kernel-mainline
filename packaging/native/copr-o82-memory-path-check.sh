#!/usr/bin/env bash
# COPR only: retained complete12000 preparation, synthetic checks and MSM object.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?Pass the remote source result directory}")
revision=${2:-1}
[[ $revision =~ ^[1-9][0-9]*$ ]]
manifest=manifests/o82-memory-path-source-20261105.json
(cd "$owner"; jq -r '.archive_assets[]|.sha256+"  "+.path' "$manifest" | sha256sum -c --strict --quiet -)
bash "$owner/packaging/native/refuse-published-release.sh" uke-o82-memory-path-check "7.3.1-$revision"
curl -q -fsSL --max-time 45 https://copr.fedorainfracloud.org/api_3/build/11260662 | \
    jq -e '.state=="succeeded" and .source_package.version=="7.3.1-12000"' >/dev/null
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
[[ ! -e $output || (-d $output && -z $(find "$output" -mindepth 1 -maxdepth 1 -print -quit)) ]]
curl -q -fLsS --retry 2 --max-time 600 --proto '=https' --proto-redir '=https' \
    "$(jq -er .kernel_parent.url "$owner/$manifest")" -o "$stage/parent.src.rpm"
printf '%s  %s\n' 7c8e9cf1da817031e5d924d3001ec6504ad1ef85693d0c55322a922f5ada0ae4 \
    "$stage/parent.src.rpm" | sha256sum -c --strict -
[[ $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$stage/parent.src.rpm") == senemos-uke-linux-kernel-mainline-unstable-7.3.1-12000.fc46 ]]
rpmkeys --checksig --nosignature --verbose "$stage/parent.src.rpm"
rpm2cpio "$stage/parent.src.rpm" > "$stage/parent.cpio"
cpio -t --quiet < "$stage/parent.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/addon"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/parent.cpio")
parent=$output/senemos-uke-linux-kernel-mainline-unstable.spec
[[ $(grep -Fxc '%prep' "$parent") == 1 && $(grep -Fxc '%build' "$parent") == 1 ]]
! grep -q '^Source99:' "$parent"
find "$output" -maxdepth 1 -type f ! -name '*.spec' -print0 | sort -z | xargs -0 sha256sum > "$stage/retained.sha256"
mapfile -t assets < <(jq -er '.archive_assets[].path' "$owner/$manifest")
git -C "$owner" archive --prefix=memory-addon/ HEAD "${assets[@]}" "$manifest" \
    LICENSE LICENSES/GPL-2.0-only.txt | tar -xf - -C "$stage/addon"
git -C "$owner" rev-parse HEAD > "$stage/addon/memory-addon/source-commit"
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
    -cJf "$output/o82-memory-path-source.tar.xz" -C "$stage/addon" memory-addon
spec=$output/uke-o82-memory-path-check.spec
awk -v revision="$revision" '
 /^%description/ {exit}
 /^Name:/ {$0="Name: uke-o82-memory-path-check"}
 /^Release:/ {$0="Release: "revision"%{?dist}"}
 /^Summary:/ {$0="Summary: Native O82 memory and protection KMS object checks"}
 /^(Requires|Provides|Recommends|Conflicts|Obsoletes|Supplements|Suggests|Enhances):/ {next}
 {print}
' "$parent" > "$spec"
cat >> "$spec" <<'SPEC'
Source99: o82-memory-path-source.tar.xz
BuildRequires: gcc-c++ clang compiler-rt python3-lxml

%description
Remote retained Linux 7.3.1 Uke source preparation, actual paired memory-color
and protection command/readback fixtures and a linked MSM object. The integer
validator matches generic binary32 arithmetic without kernel floating point.
Only a text receipt and licenses are delivered. No kernel Image, module, boot
image, executable, private calibration or firmware bundle is packaged. Existing
profile loading remains v4; JSON mapping and physical image quality are open.

SPEC
awk '/^%prep$/ {emit=1} /^%build$/ {exit} emit {print}' "$parent" >> "$spec"
cat >> "$spec" <<'SPEC'
tar -xJf %{SOURCE99}

%build
set -o pipefail
bash memory-addon/packaging/native/check-o82-memory-path.sh "$PWD" %{_uke_out} \
    | tee %{_topdir}/o82-memory-path-checks.txt

%install
install -Dm644 %{_topdir}/o82-memory-path-checks.txt %{buildroot}%{_docdir}/%{name}/checks.txt

%check
test -s %{buildroot}%{_docdir}/%{name}/checks.txt

%files
%license memory-addon/LICENSE memory-addon/LICENSES/GPL-2.0-only.txt
%{_docdir}/%{name}/checks.txt

%changelog
SPEC
day=$(date -u --date="@$epoch" '+%a %b %d %Y')
printf '* %s Uke contributors - 7.3.1-%s\n- Check native paired memory/protection programming and preserve v4 source behavior.\n' \
    "$day" "$revision" >> "$spec"
unlink "$parent"
sha256sum -c --strict --quiet "$stage/retained.sha256"
[[ $(rpmspec --target aarch64 -q --srpm --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$spec") == uke-o82-memory-path-check-7.3.1-$revision.fc46 ]]
