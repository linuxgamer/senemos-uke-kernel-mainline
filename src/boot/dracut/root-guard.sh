#!/bin/sh
# Native/POSIX initramfs boundary: admit only the selected provisioned root.
set -eu
# Invoked indirectly by the EXIT trap.
# shellcheck disable=SC2317,SC2329
root_probe_diagnostics() {
    status=$?
    [ "$status" -ne 0 ] || return 0
    echo 'UKE_PROBE_SNAPSHOT_BEGIN: root discovery failed'
    echo 'UKE_PROBE_BUILD: boot-gunyah-wdt-v5'
    echo 'UKE_PROBE_CMDLINE:'
    cat /proc/cmdline
    for name in 100000.clock-controller 1f40000.clock-controller 15000000.apps-smmu 17a00000.rsc:drv@2:rpmh-regulator-smpb2 17a00000.rsc:drv@2:rpmh-regulator-ldod1 1d80000.ufsphy_mem 1d84000.ufshc a600000.ssusb ac0000.qcom,qupv3_0_geni_se; do
        device=/sys/bus/platform/devices/$name
        if [ -L "$device/driver" ]; then
            driver=$(readlink -f "$device/driver")
            echo "$name driver=${driver##*/}"
        elif [ -d "$device" ]; then
            echo "$name UNBOUND"
        else
            echo "$name NOT_INSTANTIATED"
        fi
    done
    echo 'UKE_PROBE_DEFERRED: relevant suppliers and consumers'
    mount -t debugfs debugfs /sys/kernel/debug >/dev/null 2>&1 || :
    if [ -r /sys/kernel/debug/devices_deferred ]; then
        grep -Ei 'ufs|usb|dwc|a80000|100000|1f40000|interconnect|smmu|gpi|repeater' /sys/kernel/debug/devices_deferred | tail -8 || :
    else
        echo 'Deferred-probe reasons unavailable'
    fi
    # Consumer deferrals must not evict the supplier's earlier probe failure.
    echo 'UKE_PROBE_PROVIDER_ERRORS: SMMU and UFS regulator initialization'
    dmesg --level=emerg,alert,crit,err,warn | grep -Ei '15000000|arm-smmu|rpmh-regulator-smpb2|rpmh-regulator-ldod1|resource (smpb2|ldod1)|pm_v8_l1|pmxr?2230_s2' | grep -Evm12 'sync_state\(\) pending|deferred probe pending|supplier .*not ready|wait for supplier' || :
    echo 'UKE_PROBE_ERRORS: recent relevant kernel warnings and errors'
    dmesg --level=emerg,alert,crit,err,warn | grep -Ei 'ufs|usb|dwc|smmu|rpmh|clock|interconnect|probe|defer|geni|gpi|repeater' | grep -Ev 'sync_state\(\) pending|deferred probe pending|\+0x[[:xdigit:]]+/0x[[:xdigit:]]+' | tail -8 || :
    echo 'UKE_PROBE_SNAPSHOT_END'
    exit "$status"
}
trap 'root_probe_diagnostics' EXIT
partlabel=''
set -f
# shellcheck disable=SC2013
for argument in $(cat /proc/cmdline); do
    case "$argument" in
        root=PARTLABEL=linux|root=PARTLABEL=userdata)
            [ -z "$partlabel" ] || { echo 'UKE_ROOT_REJECTED: multiple root selectors' >&2; exit 1; }
            partlabel=${argument#root=PARTLABEL=};;
        root=*) echo 'UKE_ROOT_REJECTED: unsupported root selector' >&2; exit 1;;
    esac
done
set +f
[ -n "$partlabel" ] || { echo 'UKE_ROOT_REJECTED: missing root selector' >&2; exit 1; }
selected=/dev/disk/by-partlabel/$partlabel
read -r uptime _ < /proc/uptime
started=${uptime%%.*}
udevadm settle --timeout=40 || {
    echo 'UKE_ROOT_REJECTED: device discovery did not settle' >&2; exit 1;
}
attempt=0
while [ "$attempt" -lt 45 ]; do
    count=0
    candidate=''
    for metadata in /sys/class/block/*/uevent; do
        [ -r "$metadata" ] && [ -r "${metadata%/uevent}/partition" ] || continue
        name='' device=''
        while IFS='=' read -r key value; do
            case "$key" in PARTNAME) name=$value;; DEVNAME) device=$value;; esac
        done < "$metadata"
        [ "$name" = "$partlabel" ] || continue
        case "$(readlink -f "${metadata%/uevent}")" in
            */virtual/block/*)
                echo 'UKE_ROOT_REJECTED: root is not a physical partition' >&2; exit 1;;
            */1d84000.ufshc/*/block/*) :;;
            *) echo 'UKE_ROOT_REJECTED: root is outside the measured Uke UFS controller' >&2; exit 1;;
        esac
        count=$((count + 1))
        candidate=/dev/$device
    done
    if [ "$count" -gt 1 ]; then
        echo 'UKE_ROOT_REJECTED: multiple selected partitions' >&2; exit 1
    fi
    if [ "$count" -eq 1 ] && [ -b "$candidate" ] && [ -e "$selected" ]; then
        [ "$(readlink -f "$selected")" = "$(readlink -f "$candidate")" ] || {
            echo 'UKE_ROOT_REJECTED: partition-name link points to a different partition' >&2; exit 1;
        }
        expected=$(blkid -p -s TYPE -o value "$candidate")
        case "$partlabel:$expected" in
            linux:ext4|userdata:f2fs|userdata:ext4|userdata:xfs|userdata:btrfs) :;;
            *) echo 'UKE_ROOT_REJECTED: unexpected filesystem identity' >&2; exit 1;;
        esac
        if [ "$partlabel" = userdata ]; then
            [ "$(blkid -p -s LABEL -o value "$candidate")" = UKE_LINUX ] || {
                echo 'UKE_ROOT_REJECTED: userdata is not a provisioned UKE_LINUX filesystem' >&2; exit 1;
            }
        fi
        if [ "$expected" = btrfs ]; then
            # Linux btrfs_super_block: num_devices is LE64 at 64 KiB + 136.
            members=$(od --endian=little -An -tu8 -j 65672 -N 8 "$candidate" | tr -d ' \n')
            [ "$members" = 1 ] || { echo 'UKE_ROOT_REJECTED: single-device Btrfs required' >&2; exit 1; }
            uuid=$(blkid -p -s UUID -o value "$candidate")
            [ -n "$uuid" ] || { echo 'UKE_ROOT_REJECTED: missing Btrfs UUID' >&2; exit 1; }
            matches=0
            for metadata in /sys/class/block/*/uevent; do
                [ -r "$metadata" ] || continue
                node=${metadata%/uevent}
                probe=/dev/${node##*/}
                [ -b "$probe" ] || continue
                other_uuid=$(blkid -p -s UUID -o value "$probe" 2>/dev/null || :)
                [ "$other_uuid" != "$uuid" ] || matches=$((matches + 1))
            done
            [ "$matches" = 1 ] || { echo 'UKE_ROOT_REJECTED: ambiguous Btrfs UUID' >&2; exit 1; }
        fi
        if [ "$partlabel:$expected" = userdata:f2fs ]; then
            : > /run/uke-userdata-f2fs-root
        fi
        echo "UKE_ROOT_ADMITTED: unique physical $partlabel partition contains $expected"
        exit 0
    fi
    attempt=$((attempt + 1))
    read -r uptime _ < /proc/uptime
    [ "$(( ${uptime%%.*} - started ))" -lt 45 ] || break
    sleep 1
done
echo "UKE_ROOT_REJECTED: matching $partlabel partition unavailable" >&2
exit 1
