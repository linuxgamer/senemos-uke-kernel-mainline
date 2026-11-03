#!/usr/bin/env bash
# Native AArch64 build dependency stage; no prebuilt or OEM firmware input.
set -Eeuo pipefail
[[ $# == 2 && $2 =~ ^[0-9]+[.][0-9]+[.][0-9]+-[1-9][0-9]*(-kvm)?$ ]] || exit 2
here=$(cd -- "$(dirname -- "$0")" && pwd)
work=$(realpath -m "$1") release=$2
[[ ! -e $work ]] || { echo 'Refusing to reuse an unverified dracut base' >&2; exit 1; }
mkdir -p "$work/dracut/modules.d/92uke-abl" "$work/empty-config" "$work/base"
cp -a /usr/lib/dracut/. "$work/dracut/"
cp "$here/dracut/"* "$work/dracut/modules.d/92uke-abl/"
chmod 755 "$work/dracut/modules.d/92uke-abl/module-setup.sh"
g++ -std=c++17 -O2 -Wall -Wextra -Werror -ffile-prefix-map="$PWD"=. \
    "$here/boot-status.cpp" -o "$work/dracut/modules.d/92uke-abl/uke-boot-status"
readelf -h "$work/dracut/modules.d/92uke-abl/uke-boot-status" | grep -E 'Machine:.*AArch64' >/dev/null
g++ -std=c++17 -O2 -Wall -Wextra -Werror -ffile-prefix-map="$PWD"=. \
    "$here/userdata-grow.cpp" -o "$work/dracut/modules.d/92uke-abl/uke-userdata-grow"
readelf -h "$work/dracut/modules.d/92uke-abl/uke-userdata-grow" | grep -E 'Machine:.*AArch64' >/dev/null
command_line=$(sed -n 's/^CONFIG_CMDLINE="\(.*\)"$/\1/p' "$here/../../packaging/native/native.config")
[[ $command_line == *'root=PARTLABEL=linux '* ]]
# Root comes from the running kernel command line, including its admitted override.
dracut_line=${command_line/root=PARTLABEL=linux /}
dracut_line=${dracut_line/rootfstype=ext4,f2fs,xfs,btrfs /}
dracut_line=${dracut_line/panic=0 /}
dracutbasedir="$work/dracut" dracut --conf /dev/null --confdir "$work/empty-config" \
    --tmpdir "$work" --no-hostonly --no-hostonly-cmdline --no-early-microcode --no-kernel --gzip \
    --add uke-abl --kernel-cmdline "$dracut_line" \
    --force-drivers 'qrtr_smd qcom_pd_mapper ufs_qcom phy_qcom_qmp_ufs qcom_battmgr dwc3_qcom phy_msm_snps_eusb2_uke repeater_qti_pmic_eusb2_uke i2c_qcom_geni gpi ktz8866' \
    --filesystems 'ext4 f2fs' --omit 'network plymouth crypt systemd-cryptsetup syslog lvm mdraid btrfs i18n' \
    "$work/base.cpio.gz" "$release"
(cd "$work/base"; gzip -cd ../base.cpio.gz | cpio -idm --quiet --no-absolute-filenames)
if grep -rE '(^|[[:space:]])(root|rootfstype|panic)=' "$work/base/etc/cmdline.d"; then
    echo 'Embedded dracut defaults must not override the selected root policy' >&2; exit 1
fi
[[ ! -e $work/base/usr/lib/modules && ! -e $work/base/usr/lib/firmware ]]
[[ ! -s $work/base/etc/machine-id && ! -e $work/base/etc/shadow ]]
[[ -x $work/base/usr/libexec/uke-userdata-grow && -x $work/base/usr/sbin/fsck.f2fs && -x $work/base/usr/sbin/resize.f2fs ]]
[[ -z $(find "$work/base" \( -type b -o -type c -o -type p -o -type s \) -print -quit) ]]
# Do not expose the disposable build path in the generated tablet payload.
find "$work/base/usr/lib/dracut" -name build-parameter.txt -type f -delete
while IFS= read -r -d '' file; do
    if [[ $(od -An -tx1 -N4 "$file" | tr -d ' \n') == 7f454c46 ]]; then
        readelf -h "$file" | grep -E 'Machine:.*AArch64' >/dev/null
    fi
done < <(find "$work/base" -type f -print0)
bash "$here/../audit/check-target-privacy.sh" "$work/base"
if grep -r -a -F -l "$work" "$work/base"; then
    echo 'Disposable build path leaked into the dracut payload' >&2; exit 1
else
    status=$?
    [[ $status == 1 ]] || { echo 'Dracut path scan failed' >&2; exit 2; }
fi
printf 'dracut\nf2fs-tools\n' > "$work/owners.list"
while IFS= read -r -d '' file; do
    rpm -qf --qf '%{NAME}\n' "/${file#"$work/base/"}" 2>/dev/null >> "$work/owners.list" || :
done < <(find "$work/base" -type f -print0)
LC_ALL=C sort -u "$work/owners.list" | while IFS= read -r package; do
    [[ $package =~ ^[a-zA-Z0-9_+.-]+$ ]] || continue
    rpm -q --qf '%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\t%{SOURCERPM}\t%{LICENSE}\n' "$package"
    rpm -q --licensefiles "$package" | while IFS= read -r path; do
        [[ -f $path ]] || continue
        install -Dm644 "$path" "$work/licenses/$package/$path"
    done
done > "$work/build-rpms.tsv"
(cd "$work"; find base licenses -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) > "$work/base-files.sha256"
find "$work/base" -type l -printf '%P\t%l\n' | LC_ALL=C sort > "$work/base-links.tsv"
sha256sum "$here/boot-status.cpp" "$here/userdata-grow.cpp" "$here/userdata-grow.hpp" "$here/make-initramfs-base.sh" "$here/dracut/"* | sed "s|$here/||" > "$work/recipe-files.sha256"
printf '%s\n' "$release" > "$work/kernel-release"
