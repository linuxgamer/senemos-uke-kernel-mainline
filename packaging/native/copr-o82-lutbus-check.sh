#!/usr/bin/env bash
# COPR only: synthetic-table checks of the exact Cliffs color command encoder.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?Pass the remote source result directory}")
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
mkdir -p "$output" "$stage/uke-o82-lutbus-check-1.0"
git -C "$root" archive HEAD src/display/dpu_o82_lutbus.c src/display/dpu_o82_lutbus.h \
    src/display/dpu_o82_profiles.c src/display/dpu_o82_profiles.h \
    src/display/dpu_o82_regdma.c src/display/dpu_o82_regdma.h \
    src/display/dpu_o82_platform.c src/display/dpu_o82_platform.h \
    patches/display/0072-o82-regdma-resource.patch tests/o82-platform-contract.sh \
    src/display/o82-color-firmware.h src/display/o82-regdma.h src/display/uke-o82-hdr-format.h \
    tests/o82-lutbus-contract.c tests/o82-lutbus-contract.sh packaging/native/check-o82-color-objects.sh \
    LICENSE LICENSES/GPL-2.0-only.txt | tar -xf - -C "$stage/uke-o82-lutbus-check-1.0"
tar --sort=name --mtime=@1793664000 --owner=0 --group=0 --numeric-owner \
    -czf "$output/uke-o82-lutbus-check-1.0.tar.gz" -C "$stage" uke-o82-lutbus-check-1.0
cat > "$output/uke-o82-lutbus-check.spec" <<'SPEC'
Name: uke-o82-lutbus-check
Version: 1.0
Release: 2%{?dist}
Summary: Remote source checks of the Cliffs O82 color command encoder
License: GPL-2.0-only AND MIT
Source0: %{name}-%{version}.tar.gz
BuildArch: noarch
BuildRequires: bash gcc clang compiler-rt libasan libubsan coreutils findutils git
BuildRequires: make bc bison flex perl openssl-devel elfutils-libelf-devel llvm lld
BuildRequires: python3 python3-lxml curl tar xz
%description
Source-only byte-stream interpretation and rejection checks using synthetic
color tables. This does not start DMA, program a display or qualify HDR output.
%prep
%autosetup
%build
%install
install -d %{buildroot}%{_docdir}/%{name}
%check
set -o pipefail
bash tests/o82-lutbus-contract.sh | tee %{buildroot}%{_docdir}/%{name}/checks.txt
bash tests/o82-platform-contract.sh | tee -a %{buildroot}%{_docdir}/%{name}/checks.txt
bash packaging/native/check-o82-color-objects.sh | tee -a %{buildroot}%{_docdir}/%{name}/checks.txt
%files
%license LICENSE LICENSES/GPL-2.0-only.txt
%{_docdir}/%{name}/checks.txt
%changelog
* Tue Nov 03 2026 Uke contributors - 1.0-2
- Check separate REGDMA resource admission and runtime suspend ownership.

* Tue Nov 03 2026 Uke contributors - 1.0-1
- Interpret actual IGC4, gamut4.3 and GC1.8 packets with synthetic RGB tables.
SPEC
