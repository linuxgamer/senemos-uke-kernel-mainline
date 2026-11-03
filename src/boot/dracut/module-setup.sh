#!/bin/bash
# Upstream host-only dracut interface; excluded from the tablet root.
# shellcheck disable=SC2154
check() { return 0; }
depends() { echo systemd; }
installkernel() {
    instmods ufs_qcom phy_qcom_qmp_ufs dwc3 dwc3_qcom \
        phy_msm_snps_eusb2_uke repeater_qti_pmic_eusb2_uke \
        i2c_qcom_geni gpi g_serial usb_f_acm usbhid hid_generic xhci_hcd xhci_plat_hcd
}
install() {
    inst_multiple /bin/sh /usr/bin/bash /usr/sbin/modprobe /usr/bin/blkid /usr/bin/readlink /usr/bin/grep /usr/bin/sleep /usr/bin/cat /usr/bin/udevadm /usr/bin/mount /usr/bin/dmesg /usr/bin/tail
    inst_multiple /usr/bin/od /usr/bin/flock /usr/bin/stat /usr/bin/id /usr/bin/chmod \
        /usr/bin/mkdir /usr/bin/rmdir /usr/bin/rm /usr/bin/tr
    inst_simple "$moddir/uke-usb-network" /usr/libexec/senemos-uke/uke-usb-network
    chmod 755 "$initdir/usr/libexec/senemos-uke/uke-usb-network"
    inst_binary "$moddir/uke-boot-status" /usr/bin/uke-boot-status
    inst_binary "$moddir/uke-userdata-grow" /usr/libexec/uke-userdata-grow
    inst_multiple /usr/sbin/fsck.f2fs /usr/sbin/resize.f2fs
    inst_simple "$moddir/uke-coresight-bringup.conf" /usr/lib/modprobe.d/uke-coresight-bringup.conf
    inst_simple "$moddir/root-guard.sh" /usr/libexec/uke-root-guard
    chmod 755 "$initdir/usr/libexec/uke-root-guard"
    inst_simple "$moddir/uke-root-guard.service" "$systemdsystemunitdir/uke-root-guard.service"
    inst_simple "$moddir/uke-initrd-screen.service" "$systemdsystemunitdir/uke-initrd-screen.service"
    mkdir -p "$initdir$systemdsystemunitdir/sysroot.mount.requires"
    ln -s ../uke-root-guard.service "$initdir$systemdsystemunitdir/sysroot.mount.requires/uke-root-guard.service"
    inst_simple "$moddir/uke-userdata-grow.service" "$systemdsystemunitdir/uke-userdata-grow.service"
    ln -s ../uke-userdata-grow.service "$initdir$systemdsystemunitdir/sysroot.mount.requires/uke-userdata-grow.service"
    mkdir -p "$initdir$systemdsystemunitdir/initrd.target.wants"
    ln -s ../uke-initrd-screen.service "$initdir$systemdsystemunitdir/initrd.target.wants/uke-initrd-screen.service"
    inst_simple "$moddir/uke-initrd-deadline.service" "$systemdsystemunitdir/uke-initrd-deadline.service"
    ln -s ../uke-initrd-deadline.service "$initdir$systemdsystemunitdir/initrd.target.wants/uke-initrd-deadline.service"
    # Keep the existing peripheral debug shell available when UFS/root fails.
    for unit in uke-cdc-acm uke-cdc-shell; do
        inst_simple "$moddir/$unit.service" "$systemdsystemunitdir/$unit.service"
        mkdir -p "$initdir$systemdsystemunitdir/$unit.service.d"
        cat > "$initdir$systemdsystemunitdir/$unit.service.d/initrd.conf" <<'UNIT'
[Unit]
DefaultDependencies=no
IgnoreOnIsolate=yes
After=systemd-udev-trigger.service
Before=initrd-switch-root.target
Conflicts=initrd-switch-root.target
StartLimitIntervalSec=0
[Service]
Restart=on-failure
RestartSec=2
UNIT
    done
    ln -s ../uke-cdc-shell.service "$initdir$systemdsystemunitdir/initrd.target.wants/uke-cdc-shell.service"
}
