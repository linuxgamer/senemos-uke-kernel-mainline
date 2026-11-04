#!/usr/bin/env bash
# COPR only: protocol conversion with synthetic inputs; no device operation.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?Pass the remote source result directory}")
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
mkdir -p "$output" "$stage/uke-o82-sixzone-check-1.0"
git -C "$root" archive HEAD src/display/o82-sixzone.h tests/o82-sixzone-contract.cpp \
    manifests/o82-sixzone-source-20261104.json LICENSE |
    tar -xf - -C "$stage/uke-o82-sixzone-check-1.0"
tar --sort=name --mtime=@1793750400 --owner=0 --group=0 --numeric-owner \
    -czf "$output/uke-o82-sixzone-check-1.0.tar.gz" -C "$stage" uke-o82-sixzone-check-1.0
cat > "$output/uke-o82-sixzone-check.spec" <<'SPEC'
Name: uke-o82-sixzone-check
Version: 1.0
Release: 1%{?dist}
Summary: Synthetic checks of the O82 SixZone 2.0 protocol converter
License: MIT
Source0: %{name}-%{version}.tar.gz
BuildArch: noarch
BuildRequires: bash gcc-c++ clang compiler-rt coreutils
%description
Remote optimized and sanitized checks of integer-domain threshold conversion,
five-component packing, legacy curve selection and transactional refusal.
The package contains a text receipt only. It does not install a native converter,
private calibration, firmware or hardware writer, and does not qualify HDR.
%prep
%autosetup
%build
g++ -std=c++20 -O2 -UNDEBUG -Wall -Wextra -Werror -Isrc/display \
    tests/o82-sixzone-contract.cpp -o sixzone-optimized
clang++ -std=c++20 -O1 -g -UNDEBUG -Wall -Wextra -Werror -Isrc/display \
    -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
    tests/o82-sixzone-contract.cpp -o sixzone-sanitized
%install
install -d %{buildroot}%{_docdir}/%{name}
%check
set -o pipefail
./sixzone-optimized | tee %{buildroot}%{_docdir}/%{name}/checks.txt
./sixzone-sanitized | tee -a %{buildroot}%{_docdir}/%{name}/checks.txt
%files
%license LICENSE
%{_docdir}/%{name}/checks.txt
%changelog
* Wed Nov 04 2026 Uke contributors - 1.0-1
- Check source-derived SixZone 2.0 conversion with synthetic protocol inputs.
SPEC
