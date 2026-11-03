#!/usr/bin/env bash
# COPR only: small source checks, no kernel Image or local compiler invocation.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?Pass the remote source result directory}")
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
mkdir -p "$output" "$stage/uke-memlat-check-1.0"
git -C "$root" archive HEAD src/power/uke-memlat.c src/power/uke-memlat-policy.h \
    src/boot/uke-bwmon.h src/boot/uke-cpu-bwmon.h src/boot/uke-memlat.h \
    tests/memlat-policy-contract.sh tests/memlat-dt-contract.sh tests/memlat-lifecycle-contract.sh \
    LICENSE | tar -xf - -C "$stage/uke-memlat-check-1.0"
tar --sort=name --mtime=@1793664000 --owner=0 --group=0 --numeric-owner \
    -czf "$output/uke-memlat-check-1.0.tar.gz" -C "$stage" uke-memlat-check-1.0
cat > "$output/uke-memlat-check.spec" <<'SPEC'
Name: uke-memlat-check
Version: 1.0
Release: 1%{?dist}
Summary: Remote source checks of the native Uke memory-latency policy
License: GPL-2.0-only
Source0: %{name}-%{version}.tar.gz
BuildArch: noarch
BuildRequires: bash clang compiler-rt libasan libubsan libfdt-devel coreutils findutils gawk
%description
Source-only policy, DT and actual-function lifecycle checks with fake providers.
No hardware operation or kernel power qualification is performed.
%prep
%autosetup
%build
%install
install -d %{buildroot}%{_docdir}/%{name}
%check
set -o pipefail
for check in policy dt lifecycle; do
    bash tests/memlat-$check-contract.sh | tee -a %{buildroot}%{_docdir}/%{name}/checks.txt
done
%files
%license LICENSE
%{_docdir}/%{name}/checks.txt
%changelog
* Tue Nov 03 2026 Uke contributors - 1.0-1
- Check native policy, DT and actual lifecycle callbacks in remote build workers.
SPEC
