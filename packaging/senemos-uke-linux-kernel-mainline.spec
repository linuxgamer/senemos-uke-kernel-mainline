%global debug_package %{nil}
%global _build_id_links none
%global __os_install_post %{nil}
%global _uke_out %{_topdir}/native-kernel-out
%global uke_boot_userspace %{_topdir}/boot-userspace

Name: senemos-uke-linux-kernel-mainline
Version: 7.3.1
%if "%{version}" == "7.3.1"
%global senemos_build_release 107
%else
%global senemos_build_release 1
%endif
%global krel %{version}-%{senemos_build_release}
%global uke_audio_driver %(printf 'uke%%s' '%{krel}' | tr '.' '_')
Release: %{senemos_build_release}%{?dist}
Summary: Mainline Linux 7.3.1 Uke kernel with O82 display and Cliffs video
License: GPL-2.0-only AND MIT AND BSD-3-Clause
SourceLicense: GPL-2.0-only AND MIT AND BSD-3-Clause AND GPL-3.0-or-later AND Apache-2.0
URL: https://github.com/MCC45TR/senemos-uke-kernel-mainline
Source0: linux-%{version}.tar.xz
Source1: senemos-uke-adaptation-%{version}.tar.xz
Source2: linux-%{version}.tar.sign
Source3: linux-stable.asc
Source4: senemos-native-profile-%{version}.tar.xz
Source5: senemos-uke-boot-recipe.tar.xz
Source6: boot-payload.json
Source7: SINGLEBOOT.md
Source8: singleboot-LICENSE
ExclusiveArch: aarch64
BuildRequires: bash bc bison flex clang llvm lld make gcc gcc-c++ perl
BuildRequires: compiler-rt
BuildRequires: libasan libubsan
BuildRequires: elfutils-libelf-devel openssl-devel openssl ncurses-devel
BuildRequires: pkgconfig(libsystemd)
BuildRequires: alsa-topology-utils
BuildRequires: alsa-lib-devel alsa-utils dt-schema
BuildRequires: rsync tar xz zstd kmod git-core jq gnupg2 dtc
BuildRequires: libfdt-devel
BuildRequires: python3
BuildRequires: dracut systemd systemd-udev util-linux coreutils grep sed findutils binutils ripgrep gzip cpio f2fs-tools
Requires: %{name}-core = %{version}-%{release}
Requires: %{name}-modules = %{version}-%{release}
Requires: %{name}-dtbs = %{version}-%{release}
Requires: %{name}-boot = %{version}-%{release}
Provides: installonlypkg(kernel)

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
Provides: uke-kernel(platform-profile-qos-v1) = 1
Provides: uke-displayport-audio = 0.1.0-13%{?dist}
Requires: (wireplumber >= 0.5 if wireplumber)
Requires: (pipewire-pulseaudio >= 1.6.10-1.uke1 if pipewire-pulseaudio)
Recommends: alsa-ucm

%description core
Image with the matching source-built initramfs, configuration and source record.

%package modules
Summary: Matching Uke kernel modules
License: GPL-2.0-only AND MIT AND BSD-3-Clause
Requires: %{name}-core = %{version}-%{release}
Requires: kmod
Requires: uke-firmware >= 3.0.304.0
Provides: installonlypkg(kernel)

%description modules
Modules from the same native-profile source and configuration as the raw Image.
The native touchscreen reports input without a userspace contact processor.

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
Requires: uke-kernel-update >= 1.8.13
Requires: uke-kernel-update(guarded-automatic) >= 1
Requires: uke-kernel-update(transaction-v1) >= 1
Requires: uke-kernel-update(final-transaction-v2) >= 1
Requires: uke-boot-integration(kernel-touch-input-v2) >= 1
Requires: (uke-power-profile-backend(native-handoff-v1) >= 1 if uke-power-profile-backend)
Provides: installonlypkg(kernel)

%description boot
Kernel-only Android v4 image for boot_b and PARTLABEL=linux. The native updater
checks package identities, module digests, physical storage and power, preserves
the previous image, and verifies write readback. Android A is not an update target.

%package singleboot
Summary: Matched Uke userdata boot profile
License: MIT
Requires: %{name} = %{version}-%{release}
Requires: uke-installation-profile >= 1.3.1
Requires: uke-kernel-update(root-filesystem-v2) >= 1

%description singleboot
Selects the userdata image from this source family's exact kernel tuple.
Image, modules, DTBs and both root profiles are built once. Installation
performs no boot activation, partition write, slot selection or reboot.

%prep
uke_prep_start=$SECONDS
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

printf 'UKE_BUILD_STAGE source_prepare elapsed_s=%d\n' "$((SECONDS-uke_prep_start))"

%build
uke_build_start=$SECONDS
export ARCH=arm64 LLVM=1 LLVM_IAS=1
test -z "${UKE_PREBUILT_SWITCH_ROOT:-}"
export KBUILD_BUILD_USER=senemos KBUILD_BUILD_HOST=copr-builder KBUILD_BUILD_VERSION=1
export SOURCE_DATE_EPOCH=1793362198
export KBUILD_BUILD_TIMESTAMP="$(date -u -d "@$SOURCE_DATE_EPOCH" '+%%Y-%%m-%%d %%H:%%M:%%S UTC')"
mkdir -p %{_uke_out}
if test ! -e %{uke_boot_userspace}; then
    bash boot-recipe/src/boot/make-initramfs-base.sh %{uke_boot_userspace} '%{krel}'
fi
test "$(cat %{uke_boot_userspace}/kernel-release)" = '%{krel}'
(cd %{uke_boot_userspace}; sha256sum -c base-files.sha256)
jobs=%{?_smp_build_ncpus}%{!?_smp_build_ncpus:4}
test "$jobs" -le 8 || jobs=8
bash boot-recipe/src/boot/build-payload.sh "$PWD" %{_uke_out} %{uke_boot_userspace}/base '%{krel}' "$jobs"
for requirement in CONFIG_QCOM_UKE_ABL_DT=y CONFIG_PSI=y CONFIG_DRM_MSM=m \
    CONFIG_DRM_PANEL_XIAOMI_O82=m CONFIG_SM_DISPCC_8550=m \
    CONFIG_VIDEO_QCOM_IRIS=m CONFIG_SM_VIDEOCC_8550=m \
    CONFIG_DRM_FBDEV_EMULATION=y CONFIG_BACKLIGHT_KTZ8866=m \
    CONFIG_EXT4_FS=y CONFIG_F2FS_FS=y CONFIG_XFS_FS=y CONFIG_BTRFS_FS=y \
    CONFIG_QCOM_UKE_PLATFORM_PROFILE=y CONFIG_ACPI_PLATFORM_PROFILE=y \
    CONFIG_SND_SEQUENCER=m CONFIG_SND_SOC_UKE=m CONFIG_SND_SOC_FS19XX=m \
    CONFIG_PINCTRL_SM8650_LPASS_LPI=m CONFIG_PINCTRL_PALAWAN_LPASS_LPI=m CONFIG_FM19511_UKE=m \
    CONFIG_RC_CORE=m CONFIG_LIRC=y CONFIG_IR_SPI=m CONFIG_HW_RANDOM_QCOM=m \
    CONFIG_BLK_INLINE_ENCRYPTION=y CONFIG_SCSI_UFS_CRYPTO=y \
    CONFIG_QCOM_INLINE_CRYPTO_ENGINE=m; do
    grep -Fx "$requirement" %{_uke_out}/.config
done
grep -Fx '# CONFIG_PSI_DEFAULT_DISABLED is not set' %{_uke_out}/.config
test "$(make -s O=%{_uke_out} LOCALVERSION=-%{senemos_build_release} kernelrelease)" = '%{krel}'
bash native-profile/tests/usbss-kconfig-contract.sh "$PWD" "%{_uke_out}/scripts/kconfig/conf"

printf 'UKE_BUILD_STAGE boot_bundle elapsed_s=%d\n' "$((SECONDS-uke_build_start))"

%check
test -L %{buildroot}/usr/lib/firmware/%{krel}/qcom/uke%{krel}/POCO-Pad-X1-tplg.bin
cmp native-generated/POCO-Pad-X1-tplg.bin %{buildroot}/usr/lib/firmware/%{krel}/qcom/uke%{krel}/POCO-Pad-X1-tplg.bin
uke_check_start=$SECONDS
bash native-profile/tests/kernel-hardening-config-contract.sh %{_uke_out}/.config
bash native-profile/tests/kernel-module-signatures-contract.sh "$PWD" \
    %{buildroot}/usr/lib/modules/%{krel} %{buildroot}/usr/share/senemos/uke/%{krel}/module-signing.x509
bash native-profile/tests/msm-kms-alternate-build.sh "$PWD" %{_uke_out} %{buildroot} '%{krel}'
test ! -e %{_uke_out}/certs/signing_key.pem
test -s %{buildroot}%{_docdir}/%{name}/%{krel}/README.md
test ! -e %{buildroot}%{_docdir}/%{name}/README.md
bash native-profile/tests/unstable-upstream-contract.sh "$PWD"
bash native-profile/tests/mainline-boot-status-contract.sh
bash native-profile/tests/touch-runtime-package-contract.sh
CC=clang bash native-profile/tests/touch-protocol-contract.sh
CC=clang bash native-profile/tests/touch-transport-contract.sh
grep -Fx 'CONFIG_TOUCHSCREEN_NT36532_UKE=m' %{_uke_out}/.config
test -s %{_uke_out}/boot-modules/lib/modules/%{krel}/kernel/drivers/input/touchscreen/nt36532-uke/nt36532-uke-touch.ko.zst
modinfo -F alias %{_uke_out}/boot-modules/lib/modules/%{krel}/kernel/drivers/input/touchscreen/nt36532-uke/nt36532-uke-touch.ko.zst | grep -Fx 'spi:nt36532-uke-touch'
CC=clang bash native-profile/tests/spi-geni-completion-contract.sh drivers/spi/spi-geni-qcom.c
test ! -e %{buildroot}/usr/lib/modules/%{krel}/uke/uke-touch-capture
! grep -q '^touch_client_sha256=' %{_uke_out}/boot-manifest
CC=clang bash native-profile/tests/resin-wake-contract.sh "$PWD"
bash boot-recipe/tests/early-modules-contract.sh
CC=clang bash native-profile/tests/platform-profile-contract.sh
CC=clang bash native-profile/tests/platform-profile-framework-contract.sh "$PWD"
bash native-profile/tests/identity-contract.sh
test "$(readlink %{buildroot}/usr/lib/senemos/default-boot.img)" = kernel-updates/%{krel}/userdata.img
jq -e '.kernel_release=="%{krel}" and .automatic_kernel_activation==true' %{buildroot}/usr/share/senemos/uke/singleboot.json
bash native-profile/tests/native-firewall-contract.sh %{_uke_out}/.config %{_uke_out}
CC=clang bash native-profile/tests/llcc-sm7675-contract.sh "$PWD"
CC=clang bash native-profile/tests/llcc-gpu-startup-contract.sh drivers/gpu/drm/msm/adreno/adreno_device.c
CC=clang bash native-profile/tests/llcc-boot-fdt-contract.sh "$PWD"
CC=clang bash native-profile/tests/llcc-pmu-contract.sh
CC=clang bash native-profile/tests/bcl-hwmon-contract.sh drivers/hwmon/qcom-bcl-hwmon.c
CXX=clang++ bash native-profile/tests/bcl-alarm-lifetime-contract.sh drivers/hwmon/qcom-bcl-hwmon.c
CXX=clang++ bash native-profile/tests/bcl-uke-admission-contract.sh drivers/hwmon/qcom-bcl-hwmon.c
test -s %{_uke_out}/boot-modules/lib/modules/%{krel}/kernel/drivers/hwmon/qcom-bcl-hwmon.ko.zst
test -s %{_uke_out}/boot-modules/lib/modules/%{krel}/kernel/drivers/perf/qcom-sm7675-llcc-pmu.ko.zst
modinfo -F alias %{_uke_out}/boot-modules/lib/modules/%{krel}/kernel/drivers/perf/qcom-sm7675-llcc-pmu.ko.zst | grep -Fx 'of:N*T*Cqcom,sm7675-llcc-pmuC*'
test "$(cat native-generated/llcc-profile)" = native-v1
grep -Fx '#define UKE_LLCC_NATIVE_PROFILE 1' arch/arm64/kernel/uke-llcc-profile.h
CXX=clang++ bash native-profile/tests/uke-rpmh-resource-contract.sh native-generated/rpmh-regulator-before-native.c pre-native
CXX=clang++ bash native-profile/tests/uke-rpmh-resource-contract.sh drivers/regulator/qcom-rpmh-regulator-uke.c native
CXX=clang++ bash native-profile/tests/ktz-dimming-observation-contract.sh drivers/video/backlight/ktz8866.c
bash boot-recipe/tests/boot-image-contract.sh %{_uke_out}/boot-image
CXX=clang++ bash native-profile/tests/root-selector-contract.sh
CC=clang bash native-profile/tests/root-selector-note-contract.sh "$PWD" "$PWD/boot-recipe/lock.json"
bash boot-recipe/tests/target-privacy-contract.sh
CC=clang bash native-profile/tests/battery-protocol-contract.sh "$PWD"
CC=clang bash native-profile/tests/qrtr-handshake-contract.sh "$PWD"
CC=clang bash native-profile/tests/battery-coordinator-contract.sh "$PWD"
CC=clang bash native-profile/tests/battery-control-transport.sh "$PWD"
CC=clang bash native-profile/tests/dp-dsc-contract.sh "$PWD"
CXX=clang++ bash native-profile/tests/dp-dsc-state-contract.sh drivers/gpu/drm/msm/dp/dp_display.c
CC=clang bash native-profile/tests/dp-fec-status-contract.sh drivers/gpu/drm/msm/dp/dp_ctrl.c
CC=clang bash native-profile/tests/dp-dsc-tu-contract.sh "$PWD"
CC=clang bash native-profile/tests/battery-control-guard-contract.sh "$PWD"
CC=clang bash native-profile/tests/battery-protection-contract.sh "$PWD"
CC=clang bash native-profile/tests/battery-settings-contract.sh "$PWD"
CC=clang bash native-profile/tests/battery-preconfigured-cap-contract.sh "$PWD"
CC=clang bash native-profile/tests/battery-preconfigured-apply-contract.sh "$PWD"
CC=clang bash native-profile/tests/audio-gpr-bounds-contract.sh "$PWD"
CC=clang bash native-profile/tests/audio-prm-response-contract.sh "$PWD"
CC=clang bash native-profile/tests/audio-unmap-response-contract.sh "$PWD"
CC=clang bash native-profile/tests/audio-graph-response-contract.sh "$PWD"
CC=clang bash native-profile/tests/audio-port-lifetime-contract.sh "$PWD"
CC=clang bash native-profile/tests/audio-rx-queue-contract.sh "$PWD"
CC=clang bash native-profile/tests/audio-compress-lock-contract.sh "$PWD"
CC=clang bash native-profile/tests/audio-buffer-submit-contract.sh "$PWD"
CC=clang bash native-profile/tests/audio-graph-lifetime-contract.sh "$PWD"
CC=clang bash native-profile/tests/audio-service-lifetime-contract.sh "$PWD"
CC=clang bash native-profile/tests/audio-service-add-contract.sh "$PWD"
CC=clang bash native-profile/tests/audio-readiness-contract.sh "$PWD"
CXX=clang++ bash native-profile/tests/audio-preset-contract.sh
CXX=clang++ bash native-profile/tests/audio-acdb-contract.sh
CC=clang bash native-profile/tests/audio-card-contract.sh "$PWD"
CC=clang bash native-profile/tests/microphone-gain-contract.sh
CC=clang bash native-profile/tests/audio-eld-contract.sh
CXX=clang++ bash native-profile/tests/kernel-audio-policy-contract.sh
CC=clang bash native-profile/tests/audio-fs19xx-contract.sh "$PWD"
CC=clang bash native-profile/tests/audio-fs19xx-lifecycle-contract.sh "$PWD"
CC=clang bash native-profile/tests/audio-probe-contract.sh "$PWD"
CC=clang bash native-profile/tests/audio-tdm-sink-contract.sh "$PWD"
CC=clang bash native-profile/tests/audio-topology-errors-contract.sh "$PWD"
test -s %{_uke_out}/sound/core/seq/snd-seq.ko
bash native-profile/tests/audio-services-fdt-contract.sh
CXX=clang++ bash native-profile/tests/offline-boot-contract.sh
bash native-profile/tests/serial-power-budget-contract.sh "$PWD"
bash native-profile/tests/usb-charger-readiness-contract.sh "$PWD"
CC=clang bash native-profile/tests/usb-qmp-tables.sh "$PWD"
CC=clang bash native-profile/tests/usb-utmi-resume-contract.sh "$PWD"
CC=clang bash native-profile/tests/usb-role-observation-contract.sh "$PWD"
CXX=clang++ bash native-profile/tests/ucsi-notification-contract.sh drivers/usb/typec/ucsi/ucsi_glink.c
CC=clang bash native-profile/tests/ucsi-transport-contract.sh drivers/usb/typec/ucsi/ucsi_glink.c
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
CC=clang bash native-profile/tests/o82-vrr-floor-contract.sh "$PWD"
CC=clang bash native-profile/tests/dpu-watchdog-lifecycle-contract.sh "$PWD"
CXX=clang++ bash native-profile/tests/dsi-panel-sequence-contract.sh drivers/gpu/drm/msm/dsi/dsi_manager.c
CXX=clang++ bash native-profile/tests/dp-connector-state-contract.sh drivers/gpu/drm/msm/dp/dp_drm.c
CXX=clang++ bash native-profile/tests/dsi-color-depth-contract.sh drivers/gpu/drm/msm/dsi/dsi_manager.c
CC=clang bash native-profile/tests/o82-mode-contract.sh native-profile/src/display/o82-mode.h native-profile/src/display/o82-data.h
CXX=clang++ bash native-profile/tests/o82-mode-valid-contract.sh drivers/gpu/drm/msm/dsi/dsi_manager.c native-profile/src/display/o82-mode.h native-profile/src/display/o82-data.h
CC=clang bash native-profile/tests/o82-panel-contract.sh native-profile/src/display/panel-xiaomi-o82.c native-profile/src/display/o82-data.h "$PWD"
CC=clang bash native-profile/tests/o82-readback-contract.sh "$PWD"
CXX=clang++ bash native-profile/tests/o82-refresh-host-contract.sh drivers/gpu/drm/msm/dsi/dsi_host.c native-profile/src/display/o82-mode.h native-profile/src/display/o82-data.h
CXX=clang++ bash native-profile/tests/o82-pll-bias-contract.sh "$PWD" %{_uke_out}
CXX=clang++ bash native-profile/tests/dpu-dsi-timing-contract.sh drivers/gpu/drm/msm/disp/dpu1/dpu_encoder_phys_vid.c drivers/gpu/drm/msm/dsi/dsi_host.c native-profile/src/display/o82-data.h native-profile/src/display/panel-xiaomi-o82.c drivers/gpu/drm/msm/disp/dpu1/dpu_hw_intf.c

CXX=clang++ bash native-profile/tests/o82-dfps-host-contract.sh drivers/gpu/drm/msm/dsi/dsi_host.c native-profile/src/display/o82-mode.h native-profile/src/display/o82-data.h
CC=clang bash native-profile/tests/o82-dfps-atomic-contract.sh drivers/gpu/drm/msm/msm_atomic.c
CC=clang bash native-profile/tests/o82-dfps-lifetime-contract.sh drivers/gpu/drm/msm/msm_atomic.c drivers/gpu/drm/msm/dsi/dsi_manager.c
CC=clang bash native-profile/tests/o82-dfps-panel-contract.sh native-profile/src/display/panel-xiaomi-o82.c native-profile/src/display/o82-data.h native-profile/src/display/o82-mode.h native-profile/src/display/qcom-uke-display.h
CC=clang bash native-profile/tests/dsi-read-transaction-contract.sh "$PWD" %{_uke_out}

printf 'UKE_BUILD_STAGE package_checks elapsed_s=%d\n' "$((SECONDS-uke_check_start))"

%install
install -Dm644 native-profile/README.md %{buildroot}%{_docdir}/%{name}/%{krel}/README.md
install -Dm644 %{SOURCE7} %{buildroot}%{_docdir}/%{name}-singleboot/SINGLEBOOT.md
install -Dm644 %{SOURCE8} %{buildroot}%{_licensedir}/%{name}-singleboot/LICENSE
install -d %{buildroot}/usr/share/senemos/uke %{buildroot}/usr/lib/senemos
cat > %{buildroot}/usr/share/senemos/uke/singleboot.json <<'EOF'
{
  "schema_version": 1,
  "package": "%{name}-singleboot",
  "kernel_release": "%{krel}",
  "root_partition": "userdata",
  "root_filesystem": "f2fs",
  "boot_selector": "senemos.root=userdata",
  "boot_image": "/usr/lib/senemos/kernel-updates/%{krel}/userdata.img",
  "automatic_kernel_activation": true
}
EOF
ln -s kernel-updates/%{krel}/userdata.img %{buildroot}/usr/lib/senemos/default-boot.img
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
depmod -b %{buildroot} -m /usr/lib/modules -a %{krel}
identity=%{buildroot}/usr/share/senemos/uke/%{krel}
mkdir -p "$identity"
bash native-profile/src/audio/desktop/install-policy.sh '%{buildroot}' '%{krel}'
install -m644 native-profile/SHA256SUMS native-profile/source-commit native-profile/README.md "$identity/"
install -m644 native-profile/source-composition.json %{_uke_out}/module-signing.x509 "$identity/"
install -m644 senemos-adaptation/source-lock.json senemos-applied-patches.txt "$identity/"
install -Dm644 native-generated/POCO-Pad-X1-AudioReach-tplg.bin \
    %{buildroot}/usr/lib/firmware/%{krel}/qcom/sm7675/POCO-Pad-X1-AudioReach-tplg.bin
install -Dm644 native-generated/POCO-Pad-X1-HDMI-tplg.bin \
    %{buildroot}/usr/lib/firmware/%{krel}/qcom/sm7675/POCO-Pad-X1-HDMI-tplg.bin
install -Dm644 native-generated/POCO-Pad-X1-tplg.bin \
    %{buildroot}/usr/lib/firmware/%{krel}/qcom/sm7675/POCO-Pad-X1-tplg.bin
# AudioReach derives this lookup from the unnormalized ASoC driver name.
install -d %{buildroot}/usr/lib/firmware/%{krel}/qcom/uke%{krel}
ln -s ../sm7675/POCO-Pad-X1-tplg.bin \
    %{buildroot}/usr/lib/firmware/%{krel}/qcom/uke%{krel}/POCO-Pad-X1-tplg.bin
cmp native-generated/POCO-Pad-X1-tplg.bin \
    %{buildroot}/usr/lib/firmware/%{krel}/qcom/uke%{krel}/POCO-Pad-X1-tplg.bin
test -z "$(find %{buildroot} -type f \( -name '*.py' -o -name '*.pyc' -o -name 'python*' \) -print -quit)"
bundle=%{buildroot}/usr/lib/senemos/kernel-updates/%{krel}
mkdir -p "$bundle"
install -m644 %{_uke_out}/linux.img "$bundle/linux.img"
install -m644 %{_uke_out}/userdata.img "$bundle/userdata.img"
install -m644 %{_uke_out}/modules.sha256 "$bundle/modules.sha256"
install -m644 %{_uke_out}/boot-manifest "$bundle/manifest"
install -m644 %{SOURCE6} "$bundle/source-lock.json"
install -m644 %{uke_boot_userspace}/build-rpms.tsv "$bundle/build-rpms.tsv"
mkdir -p %{buildroot}/usr/share/licenses/%{name}-boot-%{version}-%{release}
cp -a %{uke_boot_userspace}/licenses/. %{buildroot}/usr/share/licenses/%{name}-boot-%{version}-%{release}/
cp -a boot-recipe/src/boot/licenses/. %{buildroot}/usr/share/licenses/%{name}-boot-%{version}-%{release}/

%posttrans boot -p /bin/sh
/usr/bin/uke-kernel-update transaction /usr/lib/senemos/kernel-updates/%{krel} || exit 1

%files
%doc %{_docdir}/%{name}/%{krel}/README.md
%license COPYING
%license native-profile/src/audio/LICENSE.audioreach-topology

%files core
%dir /usr/lib/modules/%{krel}
/usr/lib/modules/%{krel}/vmlinuz
/usr/lib/modules/%{krel}/config
/usr/lib/modules/%{krel}/System.map
/usr/lib/modules/%{krel}/modules.builtin*
/usr/lib/modules/%{krel}/modules.order
/usr/share/senemos/uke/%{krel}/
/usr/lib/firmware/%{krel}/
%dir /usr/share/alsa/ucm2/Qualcomm/sm7675
/usr/share/alsa/ucm2/Qualcomm/sm7675/*.conf
%dir /usr/share/alsa/ucm2/conf.d/sm7675
/usr/share/alsa/ucm2/conf.d/sm7675/*.conf
/usr/share/alsa/ucm2/Qualcomm/%{uke_audio_driver}/
/usr/share/alsa/ucm2/conf.d/%{uke_audio_driver}/
/usr/share/wireplumber/wireplumber.conf.d/75-uke-thp-not-camera.conf
/usr/share/wireplumber/wireplumber.conf.d/80-uke-microphone-array.conf
/usr/share/wireplumber/wireplumber.conf.d/95-uke-microphone-array-%{krel}.conf
%dir /usr/share/senemos/uke/audio
/usr/share/senemos/uke/audio/microphone-layout.json
%license /usr/share/licenses/uke-kernel-audio-%{krel}/LICENSE

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

%files singleboot
%doc %{_docdir}/%{name}-singleboot/SINGLEBOOT.md
%license %{_licensedir}/%{name}-singleboot/LICENSE
/usr/share/senemos/uke/singleboot.json
/usr/lib/senemos/default-boot.img

%changelog
* Sat Oct 31 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-106
- Make guarded automatic boot staging the singleboot package contract.
- Require the updater whose default enables verified inactive-slot delivery.

* Sat Oct 31 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-105
- Deliver the kernel-owned microphone array through the requested unstable channel.

* Sat Oct 31 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-104
- Correct the gain schema unit suffix and validation path before kernel compilation.

* Sat Oct 31 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-103
- Apply bounded DT microphone gains before codec power-up, with register rollback on errors.
- Deliver one named four-channel input and matching desktop data with the kernel.
- Preserve legacy audio data and version new policy files for parallel-kernel rollback.

* Sat Oct 31 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-102
- Preserve contiguous codec-DMA microphone IDs through the frontend converter.
- Require the corrected raw-channel capability for desktop capture.

* Sat Oct 31 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-101
- Admit the unmodified TX negative-control source with its existing sign warning.

* Sat Oct 31 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-100
- Track each TX decimator independently and mute every selected capture channel.
- Gate shared microphone desktop profiles on the corrected capture lifecycle.

* Sat Oct 31 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-16
- Preserve selected 1/2/4-channel capture at 48 kHz S16_LE.
- Require exact contiguous TX decimator counts and masks matching the DMA format.
- Advertise the bounded microphone capability in the running ALSA card components.

* Sat Oct 31 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-13
- Add the four OEM analog input/bias routes and native ADC output bridges.
- Keep strict mono admission and qualify the remaining inputs separately.

* Sat Oct 31 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-10
- Match the 56-byte AudioReach read-completion V2 ABI and timestamp layout.
- Keep strict reply-size, status, token, address and data-size checks.

* Sat Oct 31 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-9
- Match the component minimum to the restricted Uke mono capture frontend.
- Preserve other cards, graphs and playback limits; physical capture remains pending.

* Sat Oct 31 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-6
- Connect mono capture to the actual native WCD939x ADC1 output widget.
- Reject the incompatible OEM aggregate output in the prepared-source FDT check.

* Sat Oct 31 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-5
- Retain the release4 profile and add guarded mono microphone capture.
- Preserve four-channel speaker and stereo DisplayPort paths; hardware testing remains pending.

* Sat Oct 31 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-4
- Admit the optional Uke PM8010 N using validated firmware population and resources.
- Preserve populated variants, generic SPMI errors and the accepted rollback slot.

* Fri Oct 30 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-3
- Admit 7.3.1 in the retained alternate KMS compile check without changing drivers.
- Check actual release admission before the full build with a shell-only fixture.

* Fri Oct 30 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-2
- Bind the native stable port to the exact published 122-patch adaptation queue.
- Preserve the separate canonical 127-patch source profile and its provenance.

* Fri Oct 30 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-1
- Move to signed upstream Linux 7.3.1 with the reviewed Uke patch queue.
- Retain final DNF singleboot staging and the accepted rollback slot.

* Fri Oct 30 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-73
- Require final DNF singleboot staging and preserve the accepted rollback slot.
- Rebuild the exact release-60 driver sources with a distinct module ABI.

* Fri Oct 30 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-60
- Preserve the reviewed drivers and update stop-proof regression fixture models.
- Run final-source AVR and video-disable contracts before kernel compilation.

* Fri Oct 30 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-59
- Route boot RPM hooks through the guarded installed-profile transaction.
- Retain the reviewed scanout sources with a fresh kernel and signing identity.

* Fri Oct 30 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-58
- Retain scanout and writeback pins until completion is proved.
- Check timer flush ordering, failed teardown and destination ownership in COPR.

* Fri Oct 30 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-57
- Unwind partial KMS initialization and drain display producers before teardown.
- Verify actual failure and concurrent-withdrawal paths in COPR.

* Fri Oct 30 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-56
- Keep color updates on the encoder's reserved control blocks and clear stale resources.
- Preserve caller modeset permission and validate the actual paths in COPR.

* Fri Oct 30 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-54
- Run the actual WLAN power-sequence fixture with independently managed storage.
- Validate the complete public source recipe on the COPR source worker.

* Fri Oct 30 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-53
- Require matching module signatures and retain only the build's public certificate.
- Enable integrity lockdown, FORTIFY, hardened usercopy, Yama and restricted logs.
- Verify every packaged module and reject unsigned, tampered and wrong-key controls.

* Fri Oct 30 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-52
- Install documentation under the exact kernel release so retained kernels can coexist.
- Mark the selection package as install-only alongside its matching payloads.

* Thu Oct 29 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-49
- Hold DTO force ACK through stream setup and release it before video starts.
- Quiesce the SM7675 DTO before pixel-clock shutdown, including failed enables.
- Check actual ACK register sequencing, clock-domain guards and stream cleanup.

* Thu Oct 29 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-48
- Match OEM external-stream timing control in the existing SM7675 setup path.
- Check compressed/plain programming and unrelated-bit preservation in the real packet fixture.

* Thu Oct 29 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-47
- Trigger continuous PPS transmission with the OEM flush bit and clear stale one-shot mode.
- Check the actual flush register with both initial modes and unrelated bits retained.
- Use arithmetic three-byte line padding and model kernel power-of-two alignment correctly.

* Thu Oct 29 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-46
- Program matching active and display data windows for compressed DisplayPort streams.
- Check real interface timing registers at FHD, QHD and UHD while retaining O82 timing coverage.

* Thu Oct 29 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-45
- Program DSC packetizer words at eight bits per component while retaining PPS input depth.
- Force complete CRTC programming when selected stream packing or DSC parameters change.

* Thu Oct 29 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-44
- Hold the DRM device across attached DSC requests and refuse missing/unregistered bindings.
- Stop policy notifications and receiver monitoring before component teardown.

* Wed Oct 28 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-43
- Recompute SST admission after training negotiates a lower lane count or rate.
- Preserve DSC eligibility for a bandwidth retry instead of latching a protocol fault.

* Wed Oct 28 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-42
- Negotiate attached DSC policy through atomic state and DRM link-status recovery.
- Check receiver enable readback and monitor link, decoder and FEC state.
- Retain a failed-compression latch and separate source from physical acceptance.

* Wed Oct 28 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-41
- Select the proposed upstream GEM nonblocking-reclaim control for Uke latency.
- Preserve inactive eviction and swap, and report completed shrinker progress.
- Retain VP9/BCL safeguards; the THP-only release40 trial was canceled.

* Wed Oct 28 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-40
- Restrict the default transparent-hugepage policy to advised mappings.
- Reduce measured reclaim stalls during loaded internal-panel transitions.
- Retain release-39 VP9 and release-38 BCL safeguards and separate device gates.

* Wed Oct 28 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-39
- Recycle valid empty VP9 non-display capture buffers in both output orders.
- Retain corrupt, overflow, firmware ownership and queue submission errors.
- Keep release-38 BCL protection and separate package from device validation.

* Wed Oct 28 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-38
- Return ENODATA for an empty PM7550BA current ADC sample without renewing its cache.
- Preserve valid current samples, firmware thresholds and other PMIC descriptors.

* Wed Oct 28 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-37
- Add native PM7550BA BCL hwmon with exact Uke revision and resource admission.
- Preserve unavailable voltage samples and serialize alarm work/wake cleanup.
- Backport the matching standard hwmon emergency attributes and ABI documentation.
- Retain existing thermal references; MEMLAT/CDSP/microphone acceptance remains open.

* Wed Oct 28 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-36
- Bound the SM7675 ICC boot floor to its firmware LUT capacity.
- Preserve strict rejection of real client overvotes and existing platforms.

* Wed Oct 28 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-35
- Use exported OF CPU lookup with balanced references for modular LLCC counters.
- Admit the exact OEM NFC L7E provider while retaining POCO-only tag transport.

* Wed Oct 28 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-34
- Integrate the running release-33 audio and native touch source fixes.
- Preserve paired CPU/L3 bandwidth admission and complete-path OPP recovery.
- Add the count-only SM7675 LLCC perf provider with exclusive per-CPU events.
- Use a distinct tuple for the combined source lineage.

* Wed Oct 28 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-33
- Admit exact CPU/LLCC monitor resources with both OEM primary and L3 OPP votes.
- Preserve existing GEM requests while adding AMC/WAKE-only monitor votes.
- Use the shared L3 page and existing CPUfreq clock pair; reject unmet L3 floors.
- Retain OPP rollback/retry guards and require distinct physical acceptance.
* Tue Oct 27 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-33
- Preserve held touch identities and qualify coherent new contact groups.
- Retain interior electrode coordinates and filter single-contact patch roll.
- Keep the matched release-31 audio corrections and reviewed L3/OPP safeguards.
- Original KDE and Qt remain unchanged; desktop cancellation and Focus input acceptance remain open.

* Tue Oct 27 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-32
- Restore all owned OPP bandwidth requests after a failed multi-path vote.
- Retain rollback uncertainty and retry incomplete OPP/BWMON cached targets.
- Own the bandwidth snapshot with its paths and propagate allocation failures.
- Keep CPU/LLCC DT admission and physical acceptance open.

* Tue Oct 27 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-31
- Reject invalid native L3 clocks and zero/descending frequency tables.
- Retain native frequency width and unwind failed ICC link allocation.
- Exercise actual L3 probe/set/remove ownership and errors during preparation.
- Paired CPU/LLCC votes, multi-path OPP recovery and physical acceptance remain open.

* Tue Oct 27 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-30
- Derive native DDR BWMON OPPs from exact Uke frequencies and byte units.
- Preserve existing MC requests while adding AMC/WAKE-only monitor votes.
- Recover owned counter-read faults without committing a failed sample.
- CPU/LLCC secondary L3 voting and physical bandwidth/lifecycle checks remain open.

* Tue Oct 27 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-29
- Restore the Cliffs NSP/crypto suppliers and two/three-rail proxy ownership.
- Preserve PAS stop errors and prepare target shutdown before client removal.
- Track each proxy enable reference when bulk rollback can itself fail.
- Retain real Sysmon ACKs and test retry and legacy paths during source preparation.
- Native CDSP activation and physical lifecycle acceptance remain unqualified.

* Tue Oct 27 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-28
- Restore MDT, FastRPC buffer and remote transport lifetime guards in the 7.3 source queue.
- Bound ELF32 metadata copies and admit firmware geometry before PAS operations.
- Run actual-code host fault and sanitizer checks during source preparation.

* Tue Oct 27 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-27
- Apply reset, pin and supply dependencies to the Type-C USBSS module.
- Retain the separate fixed USB2 driver dependency scope and check both real Kconfig stanzas.

* Tue Oct 27 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-26
- Preserve the last applied BWMON bandwidth after failed OPP transactions.
- Exercise actual IRQ-thread vote errors, retries, OPP references and rearming on the host.

* Tue Oct 27 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-25
- Reuse the reviewed LPASS providers and coordinated codec reset with the current speaker graph.
- Keep one exact SM7675 pin provider and preserve the speaker TDM mux slots.
- Preserve codec supplier errors and release partial reset children before power-down.

* Tue Oct 27 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-24
- Map the admitted Cliffs MCQ configuration, operation and status regions separately.
- Bound capability-derived queues and unwind mapping failures before SDB fallback.
- Retain native main-IRQ completion handling and poll-queue exclusion.
- Preserve working SDB buffers and queue metadata until all MCQ DMA allocations commit.

* Tue Oct 27 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-23
- Connect the exact firmware-initialized Uke RNG to the upstream TRNG driver.
- Admit the exact UFS ICE/HWKM resources and retain the native host clock/power path.
- Require matching resources and retain disabled or unqualified hardware paths.

* Tue Oct 27 2026 Uke Linux project <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-22
- Preserve SKU identity, report the processor and LPDDR5X, and describe SSC-owned sensors.
- Add the POCO-only FM19511 tag transport and Uke infrared through upstream LIRC.
- Remove unreferenced panel and false fingerprint templates; physical acceptance remains pending.

* Tue Oct 27 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-21
- Contain FS19xx clock, thermal, register and stream-lifecycle failures.
- Enforce the uncalibrated volume ceiling and propagate invalid AudioReach setup.
- Require the combined-card desktop policy; microphone capture remains unavailable.

* Mon Oct 26 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-18
- Process Uke THP matrices in kernel input with a live baseline and tracked multitouch slots.
- Read touch identity, dimensions and shared electrode mapping from DT; retain lost-IRQ recovery.
- Require native boot acceptance support and run input/lifecycle fixtures in the RPM build.
* Mon Oct 26 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-17
- Report touchscreen coordinates through native input and load shared model firmware directly.
- Remove the matched userspace touch processor from the kernel payload.
* Mon Oct 26 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-16
- Add two-stream RGB8 SDR MST with payload and shared-link failure cleanup.
- Bound DP training by negotiated Type-C lanes and preserve unchanged IRQ routing.

* Mon Oct 26 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-15
- Require a fresh FEC receiver event before admitting compressed DisplayPort.
- Exercise stale detection, failed status clearing and actual compressed TU calculations.

* Mon Oct 26 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-14
- Add default-off RGB DSC with checked FEC, bounded PPS registers and atomic resource state.

* Sun Oct 25 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-13
- Drain serialized battery requests before marking the Uke transport suspended.
- Keep ambiguous delivery blocked and test the in-flight reply during suspend.

* Sun Oct 25 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-12
- Keep initialized touch firmware for gesture entry after panel blanking.
- Enforce the advertised downstream HDMI TMDS budget for DP color selection.

* Sun Oct 25 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-11
- Add checked gesture retention and selective lid-open dispatch for s2idle wake trials.
- Preserve the release-10 display, video, AUX and ELD changes.

* Sun Oct 25 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-10
- Notify the registered Uke DP PCM ELD control when its cached bytes change.
- Retain the reviewed video prerequisites and receiver diagnostic interface.

* Sun Oct 25 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-9
- Expose the standard DP AUX interface for receiver capability diagnostics.
- Retain the video implementation and reviewed OEM video configuration gates.

* Sun Oct 25 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-8
- Restore the exact OEM video configuration gates before GCC registration.
- Propagate both register-write failures; retain release-6 native video integration.
- Keep the separate Main10 source work and physical codec acceptance open.

* Sun Oct 25 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-6
- Integrate the checked native Cliffs Iris, VIDEOCC and shared SMMU path.
- Preserve the published release-4/5 display, USB and RGB source changes.
- Require private firmware before codec registration; target acceptance remains open.

* Sun Oct 25 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-5
- Validate the registered LED device name instead of its optional input name.
- Cover the RGB supplier probe with NULL-name and identity refusal fixtures.

* Sun Oct 25 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-4
- Keep the single internal and external Uke pipelines on separate CRTCs.
- Prefer the spare color mixer and preserve another stream's DSPP ownership.
- Bound UCSI debugfs responses to the negotiated protocol payload size.
- Own the RGB LED through a kernel consumer with battery and camera policy.
- Provide bounded color-test and HEX control ioctls without changing LPG electrical limits.
- Refuse competing multicolor sysfs writes while the consumer owns the LED.

* Sun Oct 25 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-3
- Keep the temporary framebuffer out of the native DSI connector namespace.
- Use the SM7675 catalog mixer width for uncompressed display topology.

* Sun Oct 25 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-2
- Integrate admitted PMXR2230 torch/RGB providers and bounded flash cleanup.
- Expose real torch brightness steps without raising the current ceiling.

* Sun Oct 25 2026 Senemos Contributors <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-1
- Prepare the matched normal and userdata family from the reviewed Linux 7.3 port.
- Initialize DSI and DP connector states through the Linux 7.3 factory.
- Preserve guarded activation and parallel module packaging.

* Sun Oct 25 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-12
- Carry the reviewed USB/DP routing, audio, HDR and lane-ceiling changes from 7.2.12.
- Retain the WLAN lifetime fix, early console and bounded boot observations.
- Preserve Linux 7.3 API adaptations and the non-activating unstable singleboot tuple.

* Sat Oct 24 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-11
- Avoid blocking optional SMMU fault capture behind GPU recovery's mutex.
- Check actual capture and fault-completion lock-cycle behavior before building.
- Use the buffered touch source exporter and first-valid-frame readiness.
- Preserve the existing unstable profile and device policies.

* Fri Oct 23 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-9
- Export the native touchscreen SPI alias for standard module autoload.
- Preserve SPI-core byte accounting after successful GENI GPI DMA transfers.
- Check the built alias and actual DMA callback success and failure paths.

* Fri Oct 23 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-8
- Scope fixed-board drivers and DTB compilation to Uke with explicit clock suppliers.
- Retain the family boot, touch, QRTR and singleboot contracts with early dependency validation.
* Fri Oct 23 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.3.0-7
- Carry the matched touch runtime and transport-ready QRTR handshake from mainline19.
- Retain Linux 7.3 compatibility changes and the registration-only audio baseline.
- Preserve the unstable ABI and absence of activation scriptlets.

* Fri Oct 23 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.12-18
- Pair the Uke SPI/IRQ capture driver and DT with its calibrated C++ processor.
- Validate the versioned processor digest with the matching module RPM.
- Invalidate completed touch buffers before system suspend.

* Thu Oct 22 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.12-14
- Omit IOMMU attachment for the closed AudioReach registration profile.
- Supply the sequencer module required by the original Fedora ALSA load rule.

* Thu Oct 22 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.12-13
- Skip PCM construction and teardown mappings in the registration-only profile.
- Check all four PCM/compressed lifecycle entry guards before packaging.

* Thu Oct 22 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.12-12
- Register the Uke AudioReach card and frontends with PCM opens denied.
- Preserve disabled physical audio paths and version the frontend topology.
- Require the Fedora topology compiler subpackage on the build worker.

* Thu Oct 22 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.12-11
- Expose the standard volume-down wake permission on the exact Uke PMIC node.
- Preserve the accepted audio-service, display and native profile source inputs.

* Thu Oct 22 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.12-10
- Register native APM and PRM services while keeping physical audio paths disabled.
- Unwind failed router service publication before releasing the device.

* Thu Oct 22 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.12-9
- Add a guarded native Uke CPU/GPU platform-profile QoS provider.
- Retain the standard legacy profile ABI on DT without enabling ACPI tables.
- Preserve hardware frequency tables, independent thermal limits and error rollback.

* Thu Oct 22 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.12-8
- Admit required early drivers only from installed modules or the exact built-in inventory.
- Require the current-slot transaction consumer before manual userdata updates.

* Thu Oct 22 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.12-7
- Admit explicit F2FS, EXT4, XFS and single-device Btrfs userdata filesystems.
- Declare root-selector ABI v2 and retain F2FS-only offline growth.

* Wed Oct 21 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.12-6
- Complete offline userdata expansion without post-root battery RPC dependencies.
- Keep the completed initrd check active and skip repeated filesystem tools.
- Report the Uke SM7675 SoC name without changing native CPU core identities.

* Wed Oct 21 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.12-5
- Expand the provisioned F2FS userdata filesystem offline before mounting root.
- Preserve filesystem identity, the partition table and the selected-root guard.

* Wed Oct 21 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.12-4
- Report the fixed O82 10-bpc transport through the standard connector property.
- Check connector state allocation, error propagation and foreign-panel exclusion.

* Wed Oct 21 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.12-3
- Build singleboot metadata in the kernel family with exact matching dependencies.
- Identify the observed POCO SKU through the live OF model before userspace.

* Wed Oct 21 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.12-1
- Carry the 98-patch Uke profile to signed Linux 7.2.12.
- Preserve matched boot payloads, guarded updates and separate device acceptance.

* Wed Oct 21 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.11-17
- Retain a versioned Image capability and require the guarded updater.
- Confirm the independent OEM SDP adapter before USB budget writes.
- Use the current per-CPU workqueue API without changing budget semantics.

* Tue Oct 20 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.11-16
- Restore the kernel primitives required by the original nftables firewall backend.
- Select one root filesystem type and a bounded userdata panic restart policy.
- Exclude conflicting root policy from embedded dracut defaults.

* Tue Oct 20 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.11-15
- Select the matched Cliffs7 cache source profile and defer GPU probe until its supplier binds.
- Forward exact slot identity and private userdata VRR arguments through the forced command line.
- Preserve the existing root profiles, charging policy and disabled audio profile.

* Tue Oct 20 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.11-12
- Bound APM basic replies and propagate readiness and PRM firmware errors
- Preserve APM unmap status and separate data/position buffer handles
- Correlate PRM replies with one pending token, opcode and parameter
- Bound graph events, DMA response payloads and period indices
- Drain dynamic GPR callbacks before port and graph state release
- Detach APR receive batches under the IRQ-safe queue lock
- Use a sleepable lock around compressed stream command submission
- Preserve 128 KiB token lengths and validate fragment submissions
- Reject failed or mismatched DMA completions without false progress
- Qualify graph OPEN, quarantine failed IDs and guard graph references
- Quiesce native audio services before topology and driver-data teardown
- Keep audio disabled; add actual-source response regression fixtures

* Tue Oct 20 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.11-11
- Expose cached UCSI GLINK request results, service epochs and event timestamps.
- Validate error/refusal bookkeeping without changing transport or routing policy.

* Tue Oct 20 2026 Senemos Maintainers <75160848+MCC45TR@users.noreply.github.com> - 7.2.11-10
- Gate Uke charging on qualified moisture, thermal and periodic fault checks.
- Add fixed owned input suspension and preserve unqualified physical status.

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
