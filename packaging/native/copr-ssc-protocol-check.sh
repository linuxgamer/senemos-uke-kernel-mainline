#!/usr/bin/env bash
# COPR only: bounded native decoder tests, no target sensor request.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?Pass the remote source result directory}")
bash "$root/packaging/native/refuse-published-release.sh" uke-ssc-protocol-check 1.0-10
(cd "$root"; jq -r '.inputs[]|.sha256+"  "+.path' \
    manifests/ssc-observation-source-20261104.json | sha256sum -c --strict --quiet -)
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
mkdir -p "$output" "$stage/uke-ssc-protocol-check-1.0"
git -C "$root" archive HEAD src/sensors/uke-ssc-protocol.c src/sensors/uke-ssc-protocol.h \
    src/sensors/uke-ssc-iio.c src/sensors/Kconfig src/sensors/Makefile src/sensors/prepare-source.sh \
    src/sensors/sysfs-driver-uke-ssc \
    manifests/ssc-observation-source-20261104.json \
    tests/ssc-protocol-contract.c tests/ssc-protocol-contract.sh \
    tests/ssc-native-contract.c tests/ssc-native-contract.sh tests/ssc-native-host.h tests/ssc-supplier-contract.sh \
    src/boot/uke-hardware.h tests/hardware-dt.cpp tests/hardware-dt.sh \
    packaging/native/check-ssc-native-objects.sh \
    LICENSE LICENSES/GPL-2.0-only.txt | tar -xf - -C "$stage/uke-ssc-protocol-check-1.0"
tar --sort=name --mtime=@1793664000 --owner=0 --group=0 --numeric-owner \
    -czf "$output/uke-ssc-protocol-check-1.0.tar.gz" -C "$stage" uke-ssc-protocol-check-1.0
cat > "$output/uke-ssc-protocol-check.spec" <<'SPEC'
Name: uke-ssc-protocol-check
Version: 1.0
Release: 10%{?dist}
Summary: Remote checks of the native Uke SSC protocol decoder
License: GPL-2.0-only AND MIT
Source0: %{name}-%{version}.tar.gz
BuildArch: noarch
BuildRequires: bash gcc gcc-c++ clang compiler-rt libasan libubsan coreutils findutils git libfdt-devel
BuildRequires: make bc bison flex perl openssl-devel elfutils-libelf-devel curl tar xz
%description
Synthetic source checks of bounded SSC protobuf parsing and integer conversion.
No QRTR request, hardware probing, calibration or physical acceptance is performed.
Read-only discovery status and generation-scoped failure reporting are checked
through the actual callbacks and reconcile worker with fake providers.
%prep
%autosetup
%build
%install
install -d %{buildroot}%{_docdir}/%{name}
%check
set -o pipefail
bash tests/ssc-protocol-contract.sh | tee %{buildroot}%{_docdir}/%{name}/checks.txt
bash tests/ssc-supplier-contract.sh | tee -a %{buildroot}%{_docdir}/%{name}/checks.txt
CXX=clang++ bash tests/hardware-dt.sh | tee -a %{buildroot}%{_docdir}/%{name}/checks.txt
bash packaging/native/check-ssc-native-objects.sh | tee -a %{buildroot}%{_docdir}/%{name}/checks.txt
%files
%license LICENSE LICENSES/GPL-2.0-only.txt
%{_docdir}/%{name}/checks.txt
%changelog
* Wed Nov 04 2026 Uke contributors - 1.0-10
- Expose read-only SSC discovery counts and the last failure stage.
- Check actual reconcile failures, stale generations and callback privacy.
- Retain protocol, supplier, Device Tree and native Linux object checks.

* Wed Nov 04 2026 Uke contributors - 1.0-9
- Request large SSC reports and validate both documented indication IDs.
- Check actual Control TLVs, maximum payloads and complete QMI sample dispatch.

* Tue Nov 03 2026 Uke contributors - 1.0-8
- Defer SSC admission until ADSP has bound and serialize managed link creation.

* Tue Nov 03 2026 Uke contributors - 1.0-7
- Check native physical sensor temperature, millicelsius scaling and its DT entry.

* Tue Nov 03 2026 Uke contributors - 1.0-6
- Validate QMI framing before decoding and preserve transaction lock ownership.

* Tue Nov 03 2026 Uke contributors - 1.0-5
- Extract callback definitions without mistaking forward declarations for bodies.

* Tue Nov 03 2026 Uke contributors - 1.0-4
- Supply the pinned kernel limits and errno constants in the host QMI fixture.

* Tue Nov 03 2026 Uke contributors - 1.0-3
- Check the actual QMI/IIO callbacks, upstream wire encoding and kernel objects.

* Tue Nov 03 2026 Uke contributors - 1.0-2
- Check exact metadata admission and bounded APSS request construction.

* Tue Nov 03 2026 Uke contributors - 1.0-1
- Check native event decoding and fixed-point arithmetic with synthetic inputs.
SPEC
