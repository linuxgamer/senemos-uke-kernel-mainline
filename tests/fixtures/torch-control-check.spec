Name: uke-control-kernel-check
Version: 2.4.0
Release: 0.7%{?dist}
Summary: Isolated source validation for Uke Control and torch ownership
License: MIT AND Apache-2.0 AND GPL-2.0-only AND (GPL-2.0-only WITH Linux-syscall-note)
Source0: %{name}-%{version}.tar.gz
ExclusiveArch: aarch64
BuildRequires: gcc-c++ make pkgconfig(libdrm) pkgconfig(libsystemd) >= 257
BuildRequires: pkgconfig(wayland-client) wayland-devel wayland-protocols-devel
BuildRequires: pkgconfig(libselinux) systemd-rpm-macros
BuildRequires: libdnf5-devel >= 5.4.6.0 pkgconfig(rpm)
BuildRequires: dbus-daemon jq selinux-policy-devel
BuildRequires: pkgconfig(jsoncpp) pkgconfig(blkid) pkgconfig(openssl)
BuildRequires: xfsprogs-devel e2fsprogs dosfstools f2fs-tools
BuildRequires: kernel-devel elfutils-libelf-devel openssl-devel libubsan
BuildRequires: util-linux coreutils diffutils
BuildRequires: pkgconfig(Qt6Gui) pkgconfig(Qt6Qml) pkgconfig(Qt6DBus)
BuildRequires: libplasma plasma5support kf6-kirigami nodejs
%description
Build-only validation of kernel torch ownership and Control request transport.
Contains a text receipt only. No runtime application or module is installed.
%package -n uke-control-native-check-assets
Summary: Uninstalled candidate applet assets for isolated visual review
License: GPL-3.0-or-later
%description -n uke-control-native-check-assets
Candidate QML and its unprivileged IPC plugin in a validation-only directory.
Does not replace an installed widget, runtime application or kernel module.
%prep
%setup -q
%build
%set_build_flags
make -j2 -C hardware/uke-control all
make -j2 -C hardware/uke-desktop-metas all
mkdir module
cp kernel/src/leds/leds-uke-torch.c kernel/src/leds/uke-torch-uapi.h module/
printf 'obj-m += leds-uke-torch.o\n' > module/Makefile
kbuild=$(find /usr/src/kernels -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
test -n "$kbuild"
printf 'Official Fedora kernel headers: %s\n' "${kbuild##*/}" > kernel-build.txt
make -j2 -C "$kbuild" M="$PWD/module" modules
%check
make -j2 -C hardware/uke-control check
make -j2 -C hardware/uke-desktop-metas test-applet-load test-light-client test-applet
bash hardware/uke-control/tests/kernel-lights-source.sh
bash kernel/tests/torch-lifetime.sh
bash kernel/tests/torch-supplier.sh
for name in policy lifetime supplier; do bash kernel/tests/rgb-$name.sh; done
cmp hardware/uke-control/shared/uke-torch.h kernel/src/leds/uke-torch-uapi.h
cmp hardware/uke-control/shared/uke-rgb.h kernel/src/leds/uke-rgb-uapi.h
%install
printf 'Native Control/applet checks and simulated kernel fixtures are mandatory before this RPM is emitted. Module compilation uses the recorded Fedora headers. No full Uke kernel, installation or physical acceptance.\n' > CHECK-RESULT.txt
install -Dm644 CHECK-RESULT.txt %{buildroot}%{_datadir}/doc/%{name}/CHECK-RESULT.txt
install -m644 kernel-build.txt %{buildroot}%{_datadir}/doc/%{name}/
install -d %{buildroot}%{_datadir}/uke-control-native-check/{qml,applet}
cp -a hardware/uke-desktop-metas/build/qml/. %{buildroot}%{_datadir}/uke-control-native-check/qml/
cp -a hardware/uke-desktop-metas/src/plasma-applet/. %{buildroot}%{_datadir}/uke-control-native-check/applet/
%files
%{_datadir}/doc/%{name}/
%files -n uke-control-native-check-assets
%license hardware/uke-desktop-metas/src/plasma-applet/LICENSE
%{_datadir}/uke-control-native-check/
