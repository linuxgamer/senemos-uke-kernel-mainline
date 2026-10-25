%global debug_package %{nil}
%global _build_id_links none
%global __os_install_post %{nil}
%global _uke_out %{_topdir}/native-kernel-out
%global uke_boot_userspace %{_topdir}/boot-userspace

Name: senemos-uke-linux-kernel-mainline
Version: 7.2.11
%if "%{version}" == "7.2.11"
%global senemos_build_release 31
%else
%global senemos_build_release 1
%endif
%global krel %{version}-%{senemos_build_release}
Release: %{senemos_build_release}%{?dist}
Summary: Mainline Uke kernel with the O82 display profile
License: GPL-2.0-only
URL: https://github.com/MCC45TR/senemos-uke-kernel-mainline
Source0: linux-%{version}.tar.xz
Source1: senemos-uke-adaptation-%{version}.tar.xz
Source2: linux-%{version}.tar.sign
Source3: linux-stable.asc
Source4: senemos-native-profile-%{version}.tar.xz
Source5: senemos-uke-boot-recipe.tar.xz
Source6: boot-payload.json
ExclusiveArch: aarch64
BuildRequires: bash bc bison flex clang llvm lld make gcc gcc-c++ perl
BuildRequires: compiler-rt
BuildRequires: elfutils-libelf-devel openssl-devel ncurses-devel
BuildRequires: rsync tar xz zstd kmod git-core jq gnupg2 dtc
BuildRequires: python3
BuildRequires: dracut systemd systemd-udev util-linux coreutils grep sed findutils binutils ripgrep gzip cpio
Requires: %{name}-core = %{version}-%{release}
Requires: %{name}-modules = %{version}-%{release}
Requires: %{name}-dtbs = %{version}-%{release}
Requires: %{name}-boot = %{version}-%{release}

%description
Source-built kernel with the reviewed O82 native display profile.
The boot subpackage contains a source-built initramfs and Android v4 container
with matching modules. It contains no OEM firmware or device-private data.
Boot writes require the explicitly enabled native updater. Build success does
not establish physical tablet acceptance.

%package core
Summary: Uke kernel Image and source identity
Provides: installonlypkg(kernel)
Provides: kernel-uname-r(%{krel})

%description core
Image with the matching source-built initramfs, configuration and source record.

%package modules
Summary: Matching Uke kernel modules
Requires: %{name}-core = %{version}-%{release}
Requires: kmod
Provides: installonlypkg(kernel)

%description modules
Modules from the same native-profile source and configuration as the raw Image.

%package dtbs
Summary: Uke compile-stage device tree and native overlay
Requires: %{name}-core = %{version}-%{release}
Provides: installonlypkg(kernel)

%description dtbs
Independent compile-stage DTB and exact O82-42 native display overlay. Physical
boot requires the separately validated dynamic stock-bootloader handoff.

%package boot
Summary: Matched native-display boot bundle for Uke
Requires: %{name}-core = %{version}-%{release}
Requires: %{name}-modules = %{version}-%{release}
Requires: %{name}-dtbs = %{version}-%{release}
Requires: uke-kernel-update >= 0.1.0-15
Provides: installonlypkg(kernel)

%description boot
Kernel-only Android v4 image for boot_b and PARTLABEL=linux. The native updater
checks package identities, module digests, physical storage and power, preserves
the previous image, and verifies write readback. Android A is not an update target.

%prep
expected=$(tar -xOJf %{SOURCE1} senemos-adaptation/source-lock.json | jq -er .source_sha256)
test "$(sha256sum %{SOURCE0} | cut -d ' ' -f1)" = "$expected"
signer=$(tar -xOJf %{SOURCE1} senemos-adaptation/source-lock.json | jq -er .signer)
# GnuPG agent sockets cannot use arbitrarily long RPM build paths.
keyring=$(mktemp -d)
trap 'gpgconf --homedir "$keyring" --kill gpg-agent; rm -rf "$keyring"' EXIT
gpg --homedir "$keyring" --batch --import %{SOURCE3}
xz -cd %{SOURCE0} | gpg --homedir "$keyring" --batch --status-fd=1 \
    --verify %{SOURCE2} - > %{_topdir}/source-verification.txt
grep -F "[GNUPG:] VALIDSIG $signer " %{_topdir}/source-verification.txt
%setup -q -n linux-%{version}
tar -xJf %{SOURCE1}
jq -r '.patches[].path | split("/") | last' senemos-adaptation/source-lock.json > senemos-expected-patches.txt
cmp senemos-expected-patches.txt senemos-adaptation/patches/series
while IFS="$(printf '\t')" read -r path expected; do
    case "$path" in
        patches/*) staged="senemos-adaptation/patches/${path##*/}" ;;
        configs/*) staged="senemos-adaptation/configs/${path##*/}" ;;
        *) exit 1 ;;
    esac
    test "$(sha256sum "$staged" | cut -d ' ' -f1)" = "$expected" || exit 1
done <<EOF
$(jq -r '.patches[], .configs[] | [.path,.sha256] | @tsv' senemos-adaptation/source-lock.json)
EOF
# Keep git apply rooted here even when the RPM development tree is nested
# inside a workspace repository. Otherwise Git silently skips those paths.
git -c init.defaultBranch=senemos init -q
: > senemos-applied-patches.txt
while IFS= read -r patch_name; do
    test -n "$patch_name" || continue
    git apply --check "senemos-adaptation/patches/$patch_name" || exit 1
    git apply "senemos-adaptation/patches/$patch_name" || exit 1
    printf '%s\n' "$patch_name" >> senemos-applied-patches.txt
done < senemos-adaptation/patches/series
cmp senemos-expected-patches.txt senemos-applied-patches.txt

tar -xJf %{SOURCE4}
bash native-profile/prepare.sh "$PWD"
tar -xJf %{SOURCE5}
cmp boot-recipe/lock.json %{SOURCE6}
(cd boot-recipe; jq -r '.source_assets[] | .sha256 + "  " + .path' lock.json | sha256sum -c -)

%build
export ARCH=arm64 LLVM=1 LLVM_IAS=1
export KBUILD_BUILD_USER=senemos KBUILD_BUILD_HOST=copr-builder KBUILD_BUILD_VERSION=1
export SOURCE_DATE_EPOCH=1791725270
export KBUILD_BUILD_TIMESTAMP="$(date -u -d "@$SOURCE_DATE_EPOCH" '+%%Y-%%m-%%d %%H:%%M:%%S UTC')"
mkdir -p %{_uke_out}
if test ! -e %{uke_boot_userspace}; then
    bash boot-recipe/src/boot/make-initramfs-base.sh %{uke_boot_userspace} '%{krel}'
fi
test "$(cat %{uke_boot_userspace}/kernel-release)" = '%{krel}'
(cd %{uke_boot_userspace}; sha256sum -c base-files.sha256)
jobs=%{?_smp_build_ncpus}%{!?_smp_build_ncpus:4}
test "$jobs" -le 8 || jobs=8
if test "${UKE_PREBUILT_KERNEL:-0}" = 1; then
    test -s %{_uke_out}/cross-source.sha256
    sha256sum -c %{_uke_out}/cross-source.sha256
    for path in .config boot-initramfs.cpio.gz Module.symvers boot-manifest \
        arch/arm64/boot/Image; do
        test -s "%{_uke_out}/$path"
    done
    readelf -h %{_uke_out}/boot-image | grep -E 'Machine:.*AArch64' >/dev/null
    readelf -h %{_uke_out}/uke-offline-switch-root | grep -E 'Machine:.*AArch64' >/dev/null
    expected=$(sed -n 's/^linux_kernel_sha256=//p' %{_uke_out}/boot-manifest)
    test "$(sha256sum %{_uke_out}/arch/arm64/boot/Image | cut -d ' ' -f1)" = "$expected"
    test "$(cat %{_uke_out}/include/config/kernel.release)" = '%{krel}'
else
    bash boot-recipe/src/boot/build-payload.sh "$PWD" %{_uke_out} %{uke_boot_userspace}/base '%{krel}' "$jobs"
fi
for requirement in CONFIG_QCOM_UKE_ABL_DT=y CONFIG_PSI=y CONFIG_DRM_MSM=m \
    CONFIG_DRM_PANEL_XIAOMI_O82=m CONFIG_SM_DISPCC_8250=y \
    CONFIG_DRM_FBDEV_EMULATION=y CONFIG_BACKLIGHT_KTZ8866=m; do
    grep -Fx "$requirement" %{_uke_out}/.config
done
grep -Fx '# CONFIG_PSI_DEFAULT_DISABLED is not set' %{_uke_out}/.config
if test "${UKE_PREBUILT_KERNEL:-0}" != 1; then
    test "$(make -s O=%{_uke_out} LOCALVERSION=-%{senemos_build_release} kernelrelease)" = '%{krel}'
fi

%check
CXX=clang++ bash native-profile/tests/uke-rpmh-resource-contract.sh native-generated/rpmh-regulator-before-native.c pre-native
CXX=clang++ bash native-profile/tests/uke-rpmh-resource-contract.sh drivers/regulator/qcom-rpmh-regulator-uke.c native
CXX=clang++ bash native-profile/tests/ktz-dimming-observation-contract.sh drivers/video/backlight/ktz8866.c
bash boot-recipe/tests/boot-image-contract.sh %{_uke_out}/boot-image
bash boot-recipe/tests/target-privacy-contract.sh
CC=clang bash native-profile/tests/battery-protocol-contract.sh "$PWD"
CC=clang bash native-profile/tests/battery-coordinator-contract.sh "$PWD"
CC=clang bash native-profile/tests/battery-control-transport.sh "$PWD"
CC=clang bash native-profile/tests/battery-control-guard-contract.sh "$PWD"
CC=clang bash native-profile/tests/battery-settings-contract.sh "$PWD"
CC=clang bash native-profile/tests/battery-preconfigured-cap-contract.sh "$PWD"
CC=clang bash native-profile/tests/battery-preconfigured-apply-contract.sh "$PWD"
CC=clang bash native-profile/tests/audio-gpr-bounds-contract.sh "$PWD"
CC=clang bash native-profile/tests/audio-readiness-contract.sh "$PWD"
CXX=clang++ bash native-profile/tests/audio-preset-contract.sh
bash native-profile/tests/audio-services-fdt-contract.sh
CXX=clang++ bash native-profile/tests/offline-boot-contract.sh
bash native-profile/tests/serial-power-budget-contract.sh "$PWD"
bash native-profile/tests/usb-charger-readiness-contract.sh "$PWD"
CC=clang bash native-profile/tests/usb-qmp-tables.sh "$PWD"
CC=clang bash native-profile/tests/usb-utmi-resume-contract.sh "$PWD"
CC=clang bash native-profile/tests/usb-role-observation-contract.sh "$PWD"
CXX=clang++ bash native-profile/tests/ucsi-notification-contract.sh drivers/usb/typec/ucsi/ucsi_glink.c
CXX=clang++ bash native-profile/tests/altmode-notification-contract.sh drivers/soc/qcom/pmic_glink_altmode.c
for symbol in FW_LOADER_COMPRESS FW_LOADER_COMPRESS_XZ FW_LOADER_COMPRESS_ZSTD; do
    grep -Fx "CONFIG_$symbol=y" %{_uke_out}/.config
done
CC=clang CXX=clang++ bash native-profile/tests/pmic-adc-contract.sh "$PWD"
CC=clang bash native-profile/tests/adc5-gen3-units.sh "$PWD"
CC=clang bash native-profile/tests/adc5-gen3-scalers.sh "$PWD"
CC=clang CXX=clang++ bash native-profile/tests/hall-contract.sh "$PWD"
CC=clang bash native-profile/tests/smp2p-restart-contract.sh "$PWD"
CC=clang bash native-profile/tests/cpucp-mailbox-contract.sh "$PWD"
CC=clang bash native-profile/tests/scmi-discovery-contract.sh "$PWD"
CC=clang bash native-profile/tests/empty-oem-nodes-contract.sh "$PWD"
CC=clang bash native-profile/tests/bluetooth-fdt-contract.sh "$PWD"
CC=clang bash native-profile/tests/wlan-remove-contract.sh "$PWD"
CC=clang bash native-profile/tests/bluetooth-power-contract.sh drivers/bluetooth/hci_qca.c
grep -Fx 'CONFIG_BT_LE=y' %{_uke_out}/.config
grep -Fx 'CONFIG_BT_BNEP=m' %{_uke_out}/.config
test -s %{_uke_out}/net/bluetooth/bnep/bnep.ko
CC=clang bash native-profile/tests/lucid-reset-rate-contract.sh "$PWD"
CC=clang bash native-profile/tests/o82-avr-contract.sh "$PWD"
CC=clang bash native-profile/tests/o82-avr-retime-contract.sh drivers/gpu/drm/msm/disp/dpu1/dpu_encoder.c
CC=clang bash native-profile/tests/o82-vrr-capability-contract.sh "$PWD"
CC=clang bash native-profile/tests/dpu-watchdog-lifecycle-contract.sh "$PWD"
CXX=clang++ bash native-profile/tests/dsi-panel-sequence-contract.sh drivers/gpu/drm/msm/dsi/dsi_manager.c
CXX=clang++ bash native-profile/tests/dp-connector-state-contract.sh drivers/gpu/drm/msm/dp/dp_drm.c
CC=clang bash native-profile/tests/o82-mode-contract.sh native-profile/src/display/o82-mode.h native-profile/src/display/o82-data.h
CXX=clang++ bash native-profile/tests/o82-mode-valid-contract.sh drivers/gpu/drm/msm/dsi/dsi_manager.c native-profile/src/display/o82-mode.h native-profile/src/display/o82-data.h
CC=clang bash native-profile/tests/o82-panel-contract.sh native-profile/src/display/panel-xiaomi-o82.c native-profile/src/display/o82-data.h "$PWD"
CC=clang bash native-profile/tests/o82-readback-contract.sh "$PWD"
CXX=clang++ bash native-profile/tests/o82-refresh-host-contract.sh drivers/gpu/drm/msm/dsi/dsi_host.c native-profile/src/display/o82-mode.h native-profile/src/display/o82-data.h
CXX=clang++ bash native-profile/tests/o82-pll-bias-contract.sh "$PWD" %{_uke_out}
CXX=clang++ bash native-profile/tests/dpu-dsi-timing-contract.sh drivers/gpu/drm/msm/disp/dpu1/dpu_encoder_phys_vid.c drivers/gpu/drm/msm/dsi/dsi_host.c native-profile/src/display/o82-data.h native-profile/src/display/panel-xiaomi-o82.c

CXX=clang++ bash native-profile/tests/o82-dfps-host-contract.sh drivers/gpu/drm/msm/dsi/dsi_host.c native-profile/src/display/o82-mode.h native-profile/src/display/o82-data.h
CC=clang bash native-profile/tests/o82-dfps-atomic-contract.sh drivers/gpu/drm/msm/msm_atomic.c
CC=clang bash native-profile/tests/o82-dfps-lifetime-contract.sh drivers/gpu/drm/msm/msm_atomic.c drivers/gpu/drm/msm/dsi/dsi_manager.c
CC=clang bash native-profile/tests/o82-dfps-panel-contract.sh native-profile/src/display/panel-xiaomi-o82.c native-profile/src/display/o82-data.h native-profile/src/display/o82-mode.h native-profile/src/display/qcom-uke-display.h
CC=clang bash native-profile/tests/dsi-read-transaction-contract.sh "$PWD" %{_uke_out}

%install
export ARCH=arm64 LLVM=1
mkdir -p %{buildroot}/usr/lib/modules
cp -a %{_uke_out}/boot-modules/lib/modules/%{krel} %{buildroot}/usr/lib/modules/
module_dir=%{buildroot}/usr/lib/modules/%{krel}
install -m644 %{_uke_out}/arch/arm64/boot/Image "$module_dir/vmlinuz"
install -m644 %{_uke_out}/.config "$module_dir/config"
install -m644 %{_uke_out}/System.map "$module_dir/System.map"
mkdir -p "$module_dir/dtb/qcom" "$module_dir/dtb/overlays"
install -m644 %{_uke_out}/arch/arm64/boot/dts/qcom/sm7675-xiaomi-uke.dtb "$module_dir/dtb/qcom/"
install -m644 native-generated/display.dtbo "$module_dir/dtb/overlays/uke-o82-oem-modes.dtbo"
install -m644 native-generated/display36.dtbo "$module_dir/dtb/overlays/uke-o82-36-test.dtbo"
install -m644 native-generated/display36-rates.dtbo "$module_dir/dtb/overlays/uke-o82-36-rates-test.dtbo"
depmod -b %{buildroot} -m /usr/lib/modules -a %{krel}
identity=%{buildroot}/usr/share/senemos/uke/%{krel}
mkdir -p "$identity"
install -m644 native-profile/SHA256SUMS native-profile/source-commit native-profile/README.md "$identity/"
install -m644 senemos-adaptation/source-lock.json senemos-applied-patches.txt "$identity/"
test -z "$(find %{buildroot} -type f \( -name '*.py' -o -name '*.pyc' -o -name 'python*' \) -print -quit)"
bundle=%{buildroot}/usr/lib/senemos/kernel-updates/%{krel}
mkdir -p "$bundle"
install -m644 %{_uke_out}/linux.img "$bundle/linux.img"
install -m644 %{_uke_out}/modules.sha256 "$bundle/modules.sha256"
install -m644 %{_uke_out}/boot-manifest "$bundle/manifest"
install -m644 %{SOURCE6} "$bundle/source-lock.json"
install -m644 %{uke_boot_userspace}/build-rpms.tsv "$bundle/build-rpms.tsv"
mkdir -p %{buildroot}/usr/share/licenses/%{name}-boot-%{version}-%{release}
cp -a %{uke_boot_userspace}/licenses/. %{buildroot}/usr/share/licenses/%{name}-boot-%{version}-%{release}/
cp -a boot-recipe/src/boot/licenses/. %{buildroot}/usr/share/licenses/%{name}-boot-%{version}-%{release}/

%posttrans boot -p /bin/sh
if grep -Fxq 'automatic=1' /etc/senemos/kernel-update.conf 2>/dev/null; then
    /usr/bin/uke-kernel-update apply /usr/lib/senemos/kernel-updates/%{krel} || exit 1
fi

%files
%doc native-profile/README.md
%license COPYING

%files core
%dir /usr/lib/modules/%{krel}
/usr/lib/modules/%{krel}/vmlinuz
/usr/lib/modules/%{krel}/config
/usr/lib/modules/%{krel}/System.map
/usr/lib/modules/%{krel}/modules.builtin*
/usr/lib/modules/%{krel}/modules.order
/usr/share/senemos/uke/%{krel}/

%files modules
/usr/lib/modules/%{krel}/kernel/
/usr/lib/modules/%{krel}/modules.alias*
/usr/lib/modules/%{krel}/modules.dep*
/usr/lib/modules/%{krel}/modules.devname
/usr/lib/modules/%{krel}/modules.softdep
/usr/lib/modules/%{krel}/modules.symbols*
/usr/lib/modules/%{krel}/modules.weakdep

%files dtbs
/usr/lib/modules/%{krel}/dtb/

%files boot
/usr/lib/senemos/kernel-updates/%{krel}/
%license /usr/share/licenses/%{name}-boot-%{version}-%{release}/

%changelog
* Sun Oct 25 2026 Uke Fedora Maintainers <linuxgamer@users.noreply.github.com> - 7.2.11-31
- Add a separate O82-36 fixed 60/120 Hz trial with the proven serial startup path.

* Sat Oct 24 2026 Uke Fedora Maintainers <linuxgamer@users.noreply.github.com> - 7.2.11-30
- Add an opt-in 60 Hz O82-36 native display candidate; retain firmware scanout by default.

* Fri Oct 23 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.11-10
- Keep the firmware framebuffer on O82-36 panels; select native display only for O82-42.

* Mon Oct 19 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.11-9
- Assert SCMI transfer allocation counts in the Clang package check.

* Mon Oct 19 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.11-8
- Validate the fixed SCMI list header before reading its count, including empty lists.

* Mon Oct 19 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.11-7
- Expose error-qualified cached SCMI protocol discovery without new firmware requests.
- Reject incomplete lists in diagnostic results and retain existing consumer behavior.

* Sun Oct 18 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.11-29
- Add an explicit root-only, read-only firmware threshold query without control admission.
- Bound diagnostic GETs and reject active leases, lifecycle changes and partial results.

* Sun Oct 18 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.11-27
- Accept observed UCSI type-2 notifications with opcode-specific validation.
- Exercise the actual callback's reply, notification and lifecycle boundaries.

* Sun Oct 18 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.11-22
- Retain exact O82 live timing updates while AVR remains enabled.
- Update both AVR periods before their common timing flush without panel reset.

* Sun Oct 18 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.11-21
- Register the single battery diagnostic group with the supported managed API.
- Remove unused getter snapshots while retaining coordinated generation checks.

* Sun Oct 18 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.11-16
- Remove an unused legacy VA scalar flag that OF misinterprets as a GPIO provider.

* Sun Oct 18 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.11-15
- Translate the Uke UART wake IRQ to the falling-edge trigger used by its OEM driver.
- Enable standard Bluetooth LE and BNEP support required by desktop Bluetooth services.

* Sun Oct 18 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.11-14
- Stop O82 DSI video after both DPU timing engines and preserve panel OFF clocks.
- Preserve the five-frame watchdog budget at the experimental AVR floor.
- Correct the captured secondary SPMI resource address and vblank trace refcount.

* Sun Oct 18 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.11-13
- Align host FDT fixtures to libfdt's eight-byte buffer contract on AArch64.

* Sun Oct 18 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.11-12
- Latch EVO/OLE PLL settings on reset exit without waiting for an unavailable ACK.
- Preserve live PLL checks and propagate register-access failures.

* Sun Oct 18 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.11-11
- Disable the exact empty secondary SPMI bus and zero-length OEM demura placeholders.
- Preserve populated controllers, nonzero reservations and all phandles.

* Sun Oct 18 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.11-7
- Map OEM paired hall events to standard input switches without physical GPIO ownership.

* Sun Oct 18 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.11-6
- Admit OEM charger and battery ADC conversions with standard current and temperature units.

* Sun Oct 18 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.11-5
- Preserve SMP2P input history until a real remote restart.
- Test ordinary updates and both restart flag transitions.

* Sun Oct 18 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.11-4
- Exclude PAS from the early module list until root firmware is available.

* Sun Oct 18 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.11-3
- Expose admitted PMIC voltage and temperature channels through standard Linux interfaces.
- Correct ADC5 Gen3 voltage types and processed units.

* Sat Oct 17 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.11-2
- Restore the source-built native boot bundle with versioned matching modules.
- Use integer releases and expose signed battery power from voltage/current.

* Sat Oct 17 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.11-1.4056.1
- Enable standard Bluetooth LE HID input and RFCOMM facilities.
- Use the Uke UART speed that completes stock QCA firmware transfer.

* Sat Oct 17 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.9-1.4054.3
- Consolidate the complete O82 source profile under the mainline package name.
- Give each numeric build its own module ABI and preserve installed fallback kernels.
- Keep boot writes unavailable until the public boot producer is accepted.

* Sat Oct 17 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.9-2
- Build the native54 live-refresh source and all seven-mode contract checks.
- Retain the compile-only boundary without a flashable boot container.

* Sat Oct 17 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.9-1
- Build the complete native O82 source profile in an isolated kernel namespace.
- Keep private initramfs and unreproducible boot containers out of COPR.
