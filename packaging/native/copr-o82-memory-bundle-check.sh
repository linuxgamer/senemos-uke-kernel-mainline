#!/usr/bin/env bash
# COPR only: native private-bundle loader checks with synthetic data.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?Pass the remote source result directory}")
revision=${2:-1}
[[ $revision =~ ^[1-9][0-9]*$ ]]
bash "$root/packaging/native/refuse-published-release.sh" uke-o82-memory-bundle-check "1.0-$revision"
manifest=manifests/o82-memory-bundle-source-20261105.json
(cd "$root"; jq -r '.inputs[]|.sha256+"  "+.path' "$manifest" | sha256sum -c --strict --quiet -)
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
mkdir -p "$output" "$stage/uke-o82-memory-bundle-check-1.0"
mapfile -t paths < <(jq -r '.inputs[].path' "$root/$manifest")
git -C "$root" archive HEAD "${paths[@]}" "$manifest" LICENSE LICENSES/GPL-2.0-only.txt |
    tar -xf - -C "$stage/uke-o82-memory-bundle-check-1.0"
tar --sort=name --mtime=@1793836800 --owner=0 --group=0 --numeric-owner \
    -czf "$output/uke-o82-memory-bundle-check-1.0.tar.gz" -C "$stage" uke-o82-memory-bundle-check-1.0
cat > "$output/uke-o82-memory-bundle-check.spec" <<'SPEC'
Name: uke-o82-memory-bundle-check
Version: 1.0
Release: @REVISION@%{?dist}
Summary: Synthetic O82 v5 memory bundle and actual kernel loader checks
License: GPL-2.0-only AND MIT
Source0: %{name}-%{version}.tar.gz
BuildArch: noarch
BuildRequires: bash gcc clang compiler-rt coreutils findutils jq
%description
Remote optimized and sanitized checks of the actual v4/v5 kernel firmware
validator, loader and command encoder. Includes both supplier identities,
explicit neutral state, protection-only presets, strict filename versions,
CRC-repaired tampering and ENOENT-only fallback. Uses synthetic data only.
The package contains a text receipt and licenses. No firmware, executable,
kernel or boot image is installed. JSON conversion, complete native kernel
integration, private profile delivery and physical acceptance remain separate.
%prep
%autosetup
jq -r '.inputs[]|.sha256+"  "+.path' manifests/o82-memory-bundle-source-20261105.json | sha256sum -c --strict -
%build
%install
install -d %{buildroot}%{_docdir}/%{name}
%check
set -o pipefail
bash tests/o82-profile-loader-contract.sh . | tee %{buildroot}%{_docdir}/%{name}/checks.txt
bash tests/o82-memory-bundle-contract.sh . | tee -a %{buildroot}%{_docdir}/%{name}/checks.txt
bash tests/o82-lutbus-contract.sh | tee -a %{buildroot}%{_docdir}/%{name}/checks.txt
%files
%license LICENSE LICENSES/GPL-2.0-only.txt
%{_docdir}/%{name}/checks.txt
%changelog
* Thu Nov 05 2026 Uke contributors - 1.0-@REVISION@
- Check strict memory-payload routing while preserving v4 ownership.
SPEC
sed -i "s/@REVISION@/$revision/g" "$output/uke-o82-memory-bundle-check.spec"
[[ $(rpmspec --target aarch64 -q --srpm --qf '%{VERSION}-%{RELEASE}' \
    "$output/uke-o82-memory-bundle-check.spec") == "1.0-$revision.fc46" ]]
