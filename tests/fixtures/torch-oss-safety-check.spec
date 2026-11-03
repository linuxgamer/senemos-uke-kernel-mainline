%global debug_package %{nil}

Name: uke-torch-oss-safety-check
Version: 1.0.0
Release: 0.2%{?dist}
Summary: Isolated QCOM flash thermal error and Uke torch validation
License: GPL-2.0-only AND (GPL-2.0-only WITH Linux-syscall-note)
Source0: %{name}-%{version}.tar.gz
ExclusiveArch: aarch64
BuildRequires: gcc make git kernel-devel elfutils-libelf-devel openssl-devel
BuildRequires: coreutils diffutils libubsan libasan
%description
Build-only validation of the QCOM flash safety patch and Uke torch consumer.
Contains text receipts only. No runtime module or application is installed.
%prep
%setup -q
sha256sum --check --strict upstream-source.sha256
mkdir -p qcom-source/drivers/leds/flash
cp upstream-leds-qcom-flash.c qcom-source/drivers/leds/flash/leds-qcom-flash.c
git -C qcom-source init -q
for patch in 0010-qcom-flash-bounded-cleanup 0011-qcom-flash-torch-steps; do
    git -C qcom-source apply --check "$PWD/kernel/patches/boot/$patch.patch"
    git -C qcom-source apply "$PWD/kernel/patches/boot/$patch.patch"
done
cp qcom-source/drivers/leds/flash/leds-qcom-flash.c qcom-before-safety.c
git -C qcom-source apply --check "$PWD/kernel/patches/boot/0043-qcom-flash-preserve-thermal-errors.patch"
git -C qcom-source apply "$PWD/kernel/patches/boot/0043-qcom-flash-preserve-thermal-errors.patch"
%build
%set_build_flags
mkdir module
cp qcom-source/drivers/leds/flash/leds-qcom-flash.c module/
cp kernel/src/leds/leds-uke-torch.c kernel/src/leds/uke-torch-uapi.h module/
printf 'obj-m += leds-qcom-flash.o leds-uke-torch.o\n' > module/Makefile
kbuild=$(find /usr/src/kernels -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
test -n "$kbuild"
printf 'Official Fedora kernel headers: %s\n' "${kbuild##*/}" > kernel-build.txt
make -j2 -C "$kbuild" M="$PWD/module" modules
%check
bash kernel/tests/flash-thermal-errors.sh qcom-source/drivers/leds/flash/leds-qcom-flash.c qcom-before-safety.c
bash kernel/tests/light-brightness.sh qcom-source/drivers/leds/flash/leds-qcom-flash.c
bash kernel/tests/light-cleanup.sh qcom-source/drivers/leds/flash/leds-qcom-flash.c
bash kernel/tests/torch-lifetime.sh
bash kernel/tests/torch-supplier.sh
%install
printf 'Actual QCOM function fixtures reproduced both baseline faults and passed the corrected error matrix, brightness and cleanup checks. Uke consumer fixtures and both modules compiled against the recorded official Fedora headers. Simulated I/O only; no matched Uke kernel build or physical acceptance. No current ceiling increase.\n' > CHECK-RESULT.txt
install -Dm644 CHECK-RESULT.txt %{buildroot}%{_datadir}/doc/%{name}/CHECK-RESULT.txt
install -m644 kernel-build.txt source-pins.txt upstream-source.sha256 %{buildroot}%{_datadir}/doc/%{name}/
%files
%{_datadir}/doc/%{name}/
