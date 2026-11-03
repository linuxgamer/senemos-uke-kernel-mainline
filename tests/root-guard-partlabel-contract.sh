#!/usr/bin/env bash
# Runs the actual guard against read-only synthetic sysfs/procfs. No disk is read.
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
command -v bwrap >/dev/null
fixture=$(mktemp -d)
trap 'status=$?; if ((status)); then cat "$fixture/result" 2>/dev/null || :; fi; rm -rf "$fixture"' EXIT
block=$(find /dev -maxdepth 2 -type b -print -quit)
[[ -n $block ]] || { echo 'A block inode is required for read-only stat fixtures' >&2; exit 2; }
mkdir -p "$fixture/bin" "$fixture/dev/disk/by-partlabel" "$fixture/sys/class/block" "$fixture/sys/devices/platform/1d84000.ufshc/host0/block/fake1" "$fixture/sys/devices/virtual/block/fake2"
touch "$fixture/dev/fake1" "$fixture/dev/fake2" "$fixture/dev/null"
printf '1\n' > "$fixture/sys/devices/platform/1d84000.ufshc/host0/block/fake1/partition"
printf '1\n' > "$fixture/sys/devices/virtual/block/fake2/partition"
ln -s ../../devices/platform/1d84000.ufshc/host0/block/fake1 "$fixture/sys/class/block/fake1"
printf '10.0 0.0\n' > "$fixture/uptime"
for tool in udevadm sleep mount dmesg; do printf '#!/bin/sh\nexit 0\n' > "$fixture/bin/$tool"; chmod 755 "$fixture/bin/$tool"; done
cat > "$fixture/bin/blkid" <<'SH'
#!/bin/sh
case "$3" in
    TYPE) printf '%s\n' "$FIXTURE_TYPE";;
    LABEL) printf '%s\n' "$FIXTURE_LABEL";;
    UUID) printf 'fixture-uuid\n';;
    *) exit 2;;
esac
SH
chmod 755 "$fixture/bin/blkid"
printf '#!/bin/sh\nprintf "%%s\\n" "$FIXTURE_MEMBERS"\n' > "$fixture/bin/od"
chmod 755 "$fixture/bin/od"
members=1
run_guard() {
    bwrap --ro-bind / / --ro-bind "$fixture/sys" /sys --ro-bind "$fixture/dev" /dev \
        --dev-bind /dev/null /dev/null \
        --ro-bind "$block" /dev/fake1 --ro-bind "$block" /dev/fake2 \
        --ro-bind "$fixture/cmdline" /proc/cmdline --ro-bind "$fixture/uptime" /proc/uptime \
        --tmpfs /run --setenv PATH "$fixture/bin:/usr/bin:/bin" --setenv FIXTURE_TYPE "$type" \
        --setenv FIXTURE_LABEL "$fslabel" --setenv FIXTURE_MEMBERS "$members" \
        /bin/sh -c '/bin/sh "$1" || exit $?; if [ -e /run/uke-userdata-f2fs-root ]; then echo F2FS_MARKER; fi' \
        guard "$root/src/boot/dracut/root-guard.sh" > "$fixture/result" 2>&1
}
reject() { if run_guard; then cat "$fixture/result"; echo 'Unsafe root admitted' >&2; exit 1; fi; grep -F UKE_ROOT_REJECTED "$fixture/result" >/dev/null; }
for partlabel in linux userdata; do
    printf 'root=PARTLABEL=%s rw\n' "$partlabel" > "$fixture/cmdline"
    printf 'DEVNAME=fake1\nPARTNAME=%s\n' "$partlabel" > "$fixture/sys/devices/platform/1d84000.ufshc/host0/block/fake1/uevent"
    ln -sfn ../../fake1 "$fixture/dev/disk/by-partlabel/$partlabel"
    type=ext4 fslabel=UKE_LINUX
    [[ $partlabel != userdata ]] || type=f2fs
    run_guard
    grep -F "unique physical $partlabel partition contains $type" "$fixture/result" >/dev/null
    if [[ $partlabel == userdata ]]; then
        for type in f2fs ext4 xfs btrfs; do
            run_guard
            if [[ $type == f2fs ]]; then grep -Fxq F2FS_MARKER "$fixture/result"; else ! grep -Fxq F2FS_MARKER "$fixture/result"; fi
        done
        type=btrfs members=2; reject
        members=0; reject
        members=1
        printf 'DEVNAME=fake2\nPARTNAME=other\n' > "$fixture/sys/devices/virtual/block/fake2/uevent"
        ln -s ../../devices/virtual/block/fake2 "$fixture/sys/class/block/fake2"
        reject
        grep -Fq 'ambiguous Btrfs UUID' "$fixture/result"
        rm "$fixture/sys/class/block/fake2"
    else
        for type in f2fs xfs btrfs; do reject; done
    fi
    type=crypto_LUKS; reject
    type=ext4 fslabel=userdata
    [[ $partlabel != userdata ]] || type=f2fs
    if [[ $partlabel == userdata ]]; then reject; else run_guard; fi
    fslabel=UKE_LINUX
    ln -sfn ../../fake2 "$fixture/dev/disk/by-partlabel/$partlabel"; reject
    ln -sfn ../../fake1 "$fixture/dev/disk/by-partlabel/$partlabel"
    printf 'DEVNAME=fake2\nPARTNAME=%s\n' "$partlabel" > "$fixture/sys/devices/virtual/block/fake2/uevent"
    ln -s ../../devices/virtual/block/fake2 "$fixture/sys/class/block/fake2"; reject
    rm "$fixture/sys/class/block/fake2"
    mkdir -p "$fixture/sys/devices/platform/1d84000.ufshc/host0/block/fake2"
    cp "$fixture/sys/devices/virtual/block/fake2/"{partition,uevent} "$fixture/sys/devices/platform/1d84000.ufshc/host0/block/fake2/"
    ln -s ../../devices/platform/1d84000.ufshc/host0/block/fake2 "$fixture/sys/class/block/fake2"; reject
    rm "$fixture/sys/class/block/fake2"
    mkdir -p "$fixture/sys/devices/platform/other-controller/block/fake1"
    cp "$fixture/sys/devices/platform/1d84000.ufshc/host0/block/fake1/"{partition,uevent} "$fixture/sys/devices/platform/other-controller/block/fake1/"
    ln -sfn ../../devices/platform/other-controller/block/fake1 "$fixture/sys/class/block/fake1"; reject
    ln -sfn ../../devices/platform/1d84000.ufshc/host0/block/fake1 "$fixture/sys/class/block/fake1"
    printf 'DEVNAME=fake2\nPARTNAME=%s\n' "$partlabel" > "$fixture/sys/devices/platform/1d84000.ufshc/host0/block/fake1/uevent"
    reject
    printf 'DEVNAME=fake1\nPARTNAME=unselected\n' > "$fixture/sys/devices/platform/1d84000.ufshc/host0/block/fake1/uevent"
    reject
done
for cmdline in 'root=UUID=fixture' 'root=PARTLABEL=system' 'root=PARTLABEL=linux root=PARTLABEL=userdata' ''; do
    printf '%s\n' "$cmdline" > "$fixture/cmdline"; reject
done
echo 'EXT4 Linux/four-filesystem userdata admission, F2FS-only growth marker, Btrfs member count and physical-root refusals passed'
