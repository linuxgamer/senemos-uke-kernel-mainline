#!/usr/bin/env bash
# COPR only: bounded native decoder tests, no target sensor request.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?Pass the remote source result directory}")
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
mkdir -p "$output" "$stage/uke-ssc-protocol-check-1.0"
git -C "$root" archive HEAD src/sensors/uke-ssc-protocol.c src/sensors/uke-ssc-protocol.h \
    tests/ssc-protocol-contract.c tests/ssc-protocol-contract.sh \
    LICENSE LICENSES/GPL-2.0-only.txt | tar -xf - -C "$stage/uke-ssc-protocol-check-1.0"
tar --sort=name --mtime=@1793664000 --owner=0 --group=0 --numeric-owner \
    -czf "$output/uke-ssc-protocol-check-1.0.tar.gz" -C "$stage" uke-ssc-protocol-check-1.0
cat > "$output/uke-ssc-protocol-check.spec" <<'SPEC'
Name: uke-ssc-protocol-check
Version: 1.0
Release: 1%{?dist}
Summary: Remote checks of the native Uke SSC protocol decoder
License: GPL-2.0-only OR MIT
Source0: %{name}-%{version}.tar.gz
BuildArch: noarch
BuildRequires: bash gcc clang compiler-rt libasan libubsan coreutils findutils
%description
Synthetic source checks of bounded SSC protobuf parsing and integer conversion.
No QRTR request, hardware probing, calibration or physical acceptance is performed.
%prep
%autosetup
%build
%install
install -d %{buildroot}%{_docdir}/%{name}
%check
set -o pipefail
bash tests/ssc-protocol-contract.sh | tee %{buildroot}%{_docdir}/%{name}/checks.txt
%files
%license LICENSE LICENSES/GPL-2.0-only.txt
%{_docdir}/%{name}/checks.txt
%changelog
* Tue Nov 03 2026 Uke contributors - 1.0-1
- Check native event decoding and fixed-point arithmetic with synthetic inputs.
SPEC
