#!/usr/bin/env bash
# COPR only: synthetic scalar protocol checks; no device or private input.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?Pass the remote source result directory}")
revision=${2:-1}
[[ $revision =~ ^[1-9][0-9]*$ ]]
bash "$root/packaging/native/refuse-published-release.sh" uke-o82-hsic-check "1.0-$revision"
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
mkdir -p "$output" "$stage/uke-o82-hsic-check-1.0"
git -C "$root" archive HEAD src/display/o82-hsic.h tests/o82-hsic-contract.cpp \
    manifests/o82-hsic-source-20261104.json LICENSE |
    tar -xf - -C "$stage/uke-o82-hsic-check-1.0"
tar --sort=name --mtime=@1793750400 --owner=0 --group=0 --numeric-owner \
    -czf "$output/uke-o82-hsic-check-1.0.tar.gz" -C "$stage" uke-o82-hsic-check-1.0
cat > "$output/uke-o82-hsic-check.spec" <<'SPEC'
Name: uke-o82-hsic-check
Version: 1.0
Release: @REVISION@%{?dist}
Summary: Synthetic checks of the O82 HSIC1.7 protocol converter
License: MIT
Source0: %{name}-%{version}.tar.gz
BuildArch: noarch
BuildRequires: bash gcc-c++ clang compiler-rt coreutils
%description
Remote optimized and sanitized checks of typed HSIC scalar conversion, signed
packing, activation and refusal. An independent integer reference checks the
single-precision intermediate operations with synthetic inputs only. The RPM
contains a text receipt; no converter executable, private data, firmware or
hardware writer is installed. This does not qualify the full color/HDR path.
%prep
%autosetup
%build
g++ -std=c++20 -O2 -UNDEBUG -Wall -Wextra -Werror -Isrc/display \
    tests/o82-hsic-contract.cpp -o hsic-optimized
clang++ -std=c++20 -O1 -g -UNDEBUG -Wall -Wextra -Werror -Isrc/display \
    -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
    tests/o82-hsic-contract.cpp -o hsic-sanitized
%install
install -d %{buildroot}%{_docdir}/%{name}
%check
set -o pipefail
./hsic-optimized | tee %{buildroot}%{_docdir}/%{name}/checks.txt
./hsic-sanitized | tee -a %{buildroot}%{_docdir}/%{name}/checks.txt
%files
%license LICENSE
%{_docdir}/%{name}/checks.txt
%changelog
* Wed Nov 04 2026 Uke contributors - 1.0-@REVISION@
- Check source-derived HSIC1.7 conversion with an integer reference.
SPEC
sed -i "s/@REVISION@/$revision/g" "$output/uke-o82-hsic-check.spec"
[[ $(rpmspec --target aarch64 -q --srpm --qf '%{VERSION}-%{RELEASE}' \
    "$output/uke-o82-hsic-check.spec") == "1.0-$revision.fc46" ]]
