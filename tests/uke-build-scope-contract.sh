#!/usr/bin/env bash
# Protect Uke suppliers and generic peripherals while excluding unrelated boards.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
config=${1:-$root/packaging/native/native.config}
for symbol in ARCH_QCOM PINCTRL_CLIFFS PINCTRL_QCOM_SPMI_PMIC SM_GCC_CLIFFS \
    QCOM_CLK_RPMH QCOM_RPMH_UKE REGULATOR_QCOM_RPMH_UKE QCOM_GDSC QCOM_GDSC_REGULATOR_UKE INTERCONNECT_QCOM_CLIFFS_USB \
    QCOM_UKE_ABL_DT QCOM_UKE_PLATFORM_PROFILE ACPI_PLATFORM_PROFILE \
    EFI EFI_STUB INITRAMFS_FORCE CMDLINE_FORCE DRM_SIMPLEDRM FRAMEBUFFER_CONSOLE \
    EXT4_FS F2FS_FS XFS_FS BTRFS_FS F2FS_FS_SECURITY SECURITY_SELINUX SCSI_UFSHCD SCSI_UFS_CRYPTO \
    PM THERMAL CGROUPS NAMESPACES SECCOMP SECCOMP_FILTER KVM DEBUG_INFO_NONE LIRC \
    RESET_CONTROLLER USB_WCD939X_UKE; do
    grep -Fxq "CONFIG_$symbol=y" "$config" || { echo "Missing Uke/platform setting: $symbol" >&2; exit 1; }
done
grep -Fxq 'CONFIG_NR_CPUS=8' "$config"
for symbol in SM_GPUCC_CLIFFS SM_DISPCC_8550 DRM_MSM DRM_PANEL_XIAOMI_O82 BACKLIGHT_KTZ8866 \
    I2C_QCOM_GENI SPI_QCOM_GENI QCOM_GPI_DMA QCOM_Q6V5_PAS QCOM_FASTRPC \
    BATTERY_QCOM_BATTMGR QCOM_SPMI_ADC5_GEN3 SENSORS_QCOM_SPMI_BCL INPUT_QCOM_SMP2P_SWITCH TOUCHSCREEN_NT36532_UKE \
    SND_SOC_UKE SND_SEQUENCER ZRAM USB_UAS USB_STORAGE USB_SERIAL_CP210X USB_SERIAL_FTDI_SIO \
    USB_DWC3_QCOM USB_PHY_QCOM_UKE USB_REPEATER_QCOM_UKE TYPEC UCSI_PMIC_GLINK \
    PHY_QCOM_QMP_COMBO SCSI_UFS_QCOM UHID RC_CORE IR_SPI FM19511_UKE HW_RANDOM_QCOM \
    PINCTRL_PALAWAN_LPASS_LPI TYPEC_MUX_UKE_WCD939X QCOM_ICC_BWMON INTERCONNECT_QCOM_OSM_L3 QCOM_SM7675_LLCC_PMU; do
    grep -Eq "^CONFIG_$symbol=[ym]$" "$config" || { echo "Missing Uke/peripheral driver: $symbol" >&2; exit 1; }
done
for symbol in ARCH_BCM ARCH_MICROCHIP ARCH_NXP MTD ATA SCSI_HISI_SAS SCSI_MPT3SAS \
    ETHERNET DRM_HDLCD DRM_MALI_DISPLAY DRM_KOMEDA DRM_ETNAVIV DRM_HISI_HIBMC \
    DRM_HISI_KIRIN DRM_POWERVR DRM_PL111 DRM_TIDSS DRM_V3D OF_ALL_DTBS \
    CHROME_PLATFORMS SURFACE_PLATFORMS PCI_EPF_TEST PCI_ENDPOINT_TEST; do
    if grep -Eq "^CONFIG_$symbol=[ym]$" "$config"; then
        echo "Unrelated board driver enabled: $symbol" >&2; exit 1
    fi
done
if grep -Eq '^CONFIG_SM_VIDEOCC_8550=[ym]$' "$config"; then
    for symbol in SM_VIDEOCC_8550 VIDEO_QCOM_IRIS; do
        grep -Fxq "CONFIG_$symbol=m" "$config" || {
            echo 'Native video requires the reviewed modular VIDEOCC/Iris pair' >&2; exit 1;
        }
    done
fi
while IFS= read -r setting; do
    symbol=${setting%%=*}
    case $symbol in
        CONFIG_SM_*CC_*|CONFIG_CLK_*CC*|CONFIG_IPQ_*|CONFIG_MSM_*CC_*|CONFIG_SC_*CC_*|CONFIG_SDM_*CC_*|CONFIG_PINCTRL_*|CONFIG_INTERCONNECT_QCOM_*)
            case $symbol in
                CONFIG_SM_GCC_CLIFFS|CONFIG_SM_GPUCC_CLIFFS|CONFIG_SM_DISPCC_8550|CONFIG_SM_VIDEOCC_8550|\
                CONFIG_PINCTRL|CONFIG_PINCTRL_MSM|CONFIG_PINCTRL_CLIFFS|CONFIG_PINCTRL_QCOM_SPMI_PMIC|\
                CONFIG_PINCTRL_LPASS_LPI|CONFIG_PINCTRL_SM8650_LPASS_LPI|CONFIG_PINCTRL_PALAWAN_LPASS_LPI|CONFIG_PINCTRL_SINGLE|CONFIG_PINCTRL_GENERIC|\
                CONFIG_INTERCONNECT_QCOM_BCM_VOTER|CONFIG_INTERCONNECT_QCOM_RPMH_POSSIBLE|CONFIG_INTERCONNECT_QCOM_RPMH|CONFIG_INTERCONNECT_QCOM_CLIFFS_USB|CONFIG_INTERCONNECT_QCOM_OSM_L3) ;;
                *) echo "Unreviewed SoC supplier: $setting" >&2; exit 1;;
            esac;;
        CONFIG_DRM_PANEL_*)
            case $symbol in CONFIG_DRM_PANEL_XIAOMI_O82|CONFIG_DRM_PANEL_BRIDGE|CONFIG_DRM_PANEL_ORIENTATION_QUIRKS) ;; *) echo "Foreign panel: $setting" >&2; exit 1;; esac;;
    esac
done < <(grep -E '^CONFIG_.*=[ym]$' "$config")
bash "$root/tests/native-firewall-contract.sh" "$config"
early=$root/src/boot/early-modules.list
for path in drivers/clk/qcom/dispcc-sm8550 drivers/clk/qcom/gpucc-cliffs \
    drivers/ufs/host/ufs-qcom drivers/phy/qualcomm/phy-qcom-qmp-ufs \
    drivers/dma/qcom/gpi drivers/i2c/busses/i2c-qcom-geni drivers/video/backlight/ktz8866 \
    drivers/usb/dwc3/dwc3-qcom drivers/usb/phy/phy-msm-snps-eusb2-uke \
    drivers/usb/repeater/repeater-qti-pmic-eusb2-uke drivers/usb/gadget/legacy/g_serial \
    drivers/usb/typec/mux/wcd939x-uke-typec drivers/usb/typec/ucsi/ucsi_glink \
    drivers/soc/qcom/pmic_glink_altmode drivers/power/supply/qcom_battmgr; do
    grep -Fxq "$path.ko.zst" "$early" || { echo "Missing early Uke driver: $path" >&2; exit 1; }
done
if grep -E 'qcom_q6v5_pas|videocc-sm8550|^drivers/media/platform/qcom/iris/|^drivers/(ata/|pci/|nvme/|platform/chrome/|scsi/mpt3sas/)' "$early"; then
    echo 'Early modules include PAS/video or an unrelated board driver' >&2; exit 1
fi
if [[ $# == 2 ]]; then
    modules=$2
    while IFS= read -r path; do
        if [[ ! -s $modules/kernel/$path ]]; then
            grep -Fxq "kernel/${path%.zst}" "$modules/modules.builtin" || { echo "Missing early module or built-in: $path" >&2; exit 1; }
        fi
    done < "$early"
    awk 'FNR==NR {selected["kernel/" $0]=1; next}
        {module=$1; sub(/:$/, "", module)}
        selected[module] {for(i=2;i<=NF;i++) if(!selected[$i]) {print "Missing early dependency: " module " -> " $i; failed=1}}
        END {exit failed}' "$early" "$modules/modules.dep"
fi
if [[ $# == 0 ]]; then
    # shellcheck disable=SC2016
    grep -Fxq 'make -C "$kernel" O="$out" LOCALVERSION="$localversion" "${compiler_args[@]}" -j"$jobs" Image modules qcom/sm7675-xiaomi-uke.dtb' "$root/src/boot/build-payload.sh"
    grep -Fxq 'make O=%{_uke_out} LOCALVERSION=-senemos-uke -j%{_uke_jobs} Image qcom/sm7675-xiaomi-uke.dtb modules' "$root/configs/host/senemos-uke-linux-kernel-mainline.spec"
fi
echo 'Uke suppliers, root/recovery, USB peripherals, firewall and scoped DTB build passed; no tablet test.'
