#!/usr/bin/env bash
# Host-only stock-ABL build. The base contains no firmware or kernel modules.
set -Eeuo pipefail
trap 'printf "Boot payload failed at line %s\n" "$LINENO" >&2' ERR
[[ $# == 5 ]] || exit 2
kernel=$(realpath "$1") out=$(realpath -m "$2")
base=$(realpath "$3") release=$4 jobs=$5
[[ $release =~ ^[0-9]+\.[0-9]+\.[0-9]+-[1-9][0-9]*$ && $jobs =~ ^[1-9][0-9]*$ ]]
here=$(cd -- "$(dirname -- "$0")" && pwd)
[[ -x $base/usr/lib/systemd/systemd && -x $base/usr/libexec/uke-root-guard ]]
[[ ! -e $base/usr/lib/modules && ! -e $base/usr/lib/firmware ]]
[[ ! -s $base/etc/machine-id && ! -e $base/etc/shadow && ! -e $base/root/.ssh ]]
mkdir -p "$out"
init=$out/boot-initramfs stage=$out/boot-modules
[[ ! -e $init && ! -e $stage ]] || { echo 'Use an empty boot output for source compilation' >&2; exit 1; }
cp -a "$base" "$init"
# Compile a native initramfs handoff; normal boots retain upstream switch-root.
if [[ ${UKE_CROSS_KERNEL:-0} == 1 ]]; then
    prebuilt=$(dirname "$base")/uke-offline-switch-root
    [[ -s $prebuilt ]] || { echo 'Missing AArch64 offline switch-root' >&2; exit 2; }
    install -m755 "$prebuilt" "$out/uke-offline-switch-root"
else
    clang++ -std=c++17 -O2 -Wall -Wextra -Werror -ffile-prefix-map="$PWD"=. \
        "$here/offline-switch-root.cpp" -o "$out/uke-offline-switch-root"
fi
readelf -h "$out/uke-offline-switch-root" | grep -E 'Machine:.*AArch64' >/dev/null
install -Dm755 "$out/uke-offline-switch-root" "$init/usr/libexec/uke-offline-switch-root"
mkdir -p "$init/usr/lib/systemd/system/initrd-switch-root.service.d"
cat > "$init/usr/lib/systemd/system/initrd-switch-root.service.d/50-uke-charger.conf" <<'UNIT'
# Uke native handoff; no charger signal retains the original systemd command.
[Service]
ExecStart=
ExecStart=/usr/libexec/uke-offline-switch-root
UNIT
cp "$here/../../packaging/native/native.config" "$out/.config"
usb_profile=$(cat "$kernel/native-generated/usb-profile")
case $usb_profile in peripheral|typec-v1) ;; *) echo 'Missing USB source-profile receipt' >&2; exit 2;; esac
if [[ $usb_profile == typec-v1 ]]; then
    # The full role manager has no early legacy gadget owner or root console.
    for unit_dir in "$init/usr/lib/systemd/system" "$init/etc/systemd/system"; do
        [[ -d $unit_dir ]] || continue
        find "$unit_dir" -type l \( -name uke-cdc-acm.service -o -name uke-cdc-shell.service \) -delete
    done
    if [[ -d $init/etc/cmdline.d ]] && grep -rlF 'senemos.debug=cdc-acm' "$init/etc/cmdline.d"; then
        echo 'Legacy debug argument present in the full-profile initramfs base' >&2
        exit 1
    fi
fi
localversion=-${release#*-}
export ARCH=arm64 LLVM=1
compiler_args=()
if [[ ${UKE_CCACHE:-0} == 1 ]]; then
    command -v ccache >/dev/null || { echo 'UKE_CCACHE requires ccache' >&2; exit 2; }
    compiler_args=(CC='ccache clang' HOSTCC='ccache gcc' HOSTCXX='ccache g++')
fi
bash "$kernel/scripts/config" --file "$out/.config" --set-str INITRAMFS_SOURCE ''
make -C "$kernel" O="$out" LOCALVERSION="$localversion" "${compiler_args[@]}" olddefconfig
[[ $(make -s -C "$kernel" O="$out" LOCALVERSION="$localversion" "${compiler_args[@]}" kernelrelease) == "$release" ]]
for flag in QCOM_UKE_ABL_DT GUNYAH_WATCHDOG INITRAMFS_FORCE CMDLINE_FORCE DRM_SIMPLEDRM FRAMEBUFFER_CONSOLE; do
    grep -Fx "CONFIG_${flag}=y" "$out/.config"
done
grep -F 'root=PARTLABEL=linux ' "$out/.config"
grep -Fx 'CONFIG_QCOM_Q6V5_PAS=m' "$out/.config"
make -C "$kernel" O="$out" LOCALVERSION="$localversion" "${compiler_args[@]}" -j"$jobs" Image modules dtbs
make -C "$kernel" O="$out" LOCALVERSION="$localversion" "${compiler_args[@]}" modules_install \
    INSTALL_MOD_PATH="$stage" INSTALL_MOD_STRIP=1 DEPMOD=true
source_modules=$stage/lib/modules/$release
find "$source_modules" -maxdepth 1 -type l \( -name build -o -name source \) -delete
find "$source_modules" -type f -name '*.ko' -exec zstd -q -T1 --rm {} \;
target=$init/usr/lib/modules/$release
mkdir -p "$target/kernel"
while IFS= read -r path; do
    [[ $path =~ ^[a-zA-Z0-9_/.-]+\.ko\.zst$ && $path != *..* && -s $source_modules/kernel/$path ]]
    install -Dm644 "$source_modules/kernel/$path" "$target/kernel/$path"
done < "$here/early-modules.list"
for name in modules.builtin modules.builtin.modinfo modules.order; do
    install -m644 "$source_modules/$name" "$target/$name"
done
depmod -b "$init" "$release"
# PAS autoboot needs OEM firmware from the real root; an early failure is not retried.
[[ ! -e $target/kernel/drivers/remoteproc/qcom_q6v5_pas.ko.zst ]]
if grep -Fq '/qcom_q6v5_pas.ko' "$target/modules.dep"; then
    echo 'Early module dependencies must not start PAS before root firmware is available' >&2
    exit 1
else
    [[ $? == 1 ]]
fi
[[ -s $source_modules/kernel/drivers/remoteproc/qcom_q6v5_pas.ko.zst ]]
bash "$here/../audit/check-target-privacy.sh" "$init"
find "$init" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
(cd "$init"; find . -print0 | LC_ALL=C sort -z | cpio --null --quiet --reproducible --owner=0:0 -o -H newc) | gzip -n -9 > "$out/boot-initramfs.cpio.gz"
bash "$kernel/scripts/config" --file "$out/.config" --set-str INITRAMFS_SOURCE "$out/boot-initramfs.cpio.gz"
make -C "$kernel" O="$out" LOCALVERSION="$localversion" "${compiler_args[@]}" olddefconfig
make -C "$kernel" O="$out" LOCALVERSION="$localversion" "${compiler_args[@]}" -j"$jobs" Image
clang++ -std=c++20 -O2 -Wall -Wextra -Werror "$here/boot-image.cpp" -o "$out/boot-image"
"$out/boot-image" create "$out/arch/arm64/boot/Image" "$out/linux.img"
"$out/boot-image" inspect "$out/linux.img" > "$out/boot-header.json"
"$out/boot-image" extract "$out/linux.img" "$out/boot-readback-Image"
cmp "$out/arch/arm64/boot/Image" "$out/boot-readback-Image"
if [[ ${UKE_CROSS_KERNEL:-0} == 1 ]]; then
    prebuilt=$(dirname "$base")/boot-image-aarch64
    [[ -s $prebuilt ]] || { echo 'Missing AArch64 boot-image checker' >&2; exit 2; }
    install -m755 "$prebuilt" "$out/boot-image"
    readelf -h "$out/boot-image" | grep -E 'Machine:.*AArch64' >/dev/null
fi
(cd "$source_modules"; find kernel -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) > "$out/modules.sha256"
image=$(sha256sum "$out/linux.img" | cut -d ' ' -f1)
raw=$(sha256sum "$out/arch/arm64/boot/Image" | cut -d ' ' -f1)
inventory=$(sha256sum "$out/modules.sha256" | cut -d ' ' -f1)
printf 'format=1\nkernel_release=%s\nlinux_image_sha256=%s\nuserdata_image_sha256=unsupported\nlinux_kernel_sha256=%s\nuserdata_kernel_sha256=unsupported\nmodules_sha256=%s\n' \
    "$release" "$image" "$raw" "$inventory" > "$out/boot-manifest"
if [[ ${UKE_CROSS_KERNEL:-0} == 1 ]]; then
    (cd "$kernel"; sha256sum native-profile/SHA256SUMS \
        senemos-adaptation/source-lock.json boot-recipe/lock.json) > "$out/cross-source.sha256"
fi
