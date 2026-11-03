#!/usr/bin/env bash
# COPR only: retain release 1303 and add the native SSC QMI/IIO consumer.
set -Eeuo pipefail
trap 'status=$?; printf "SSC source preparation failed at line %s (exit %s)\n" "$LINENO" "$status" >&2; exit "$status"' ERR
export LC_ALL=C
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?COPR result directory}")
# Keep the dependent candidate queued remotely until its retained parent passes.
for attempt in {1..60}; do
    parent_state=$(curl -fsSL --max-time 45 https://copr.fedorainfracloud.org/api_3/build/11251375 | jq -er .state)
    case $parent_state in
        succeeded) break;;
        running|pending|starting|importing|waiting)
            printf 'Waiting for retained parent build 11251375: %s\n' "$parent_state"
            sleep 30;;
        *) printf 'Retained parent build did not pass: %s\n' "$parent_state" >&2; exit 1;;
    esac
done
[[ $parent_state == succeeded ]]
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline 7.3.1-1400
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
curl -fLsS --retry 2 --proto '=https' --proto-redir '=https' \
 https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/11251375/senemos-uke-linux-kernel-mainline-7.3.1-1303.src.rpm -o "$stage/base.src.rpm"
parent_hash=$(sha256sum "$stage/base.src.rpm"); parent_hash=${parent_hash%% *}
# Pin both RPM content digests; verify the complete downloaded RPM.
[[ $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$stage/base.src.rpm") == senemos-uke-linux-kernel-mainline-7.3.1-1303 ]]
[[ $(rpm -qp --qf '%{SHA256HEADER}' "$stage/base.src.rpm") == 2400e59b76391a8337994ecde731634178a733712ee6c537bf3294f64bd1beef ]]
[[ $(rpm -qp --qf '%{PAYLOADSHA256}' "$stage/base.src.rpm") == a5414d20fdbc0a20d8e3f055d959367a9c2b5de8ed8ba31f4e12dbaf476e9daa ]]
rpmkeys --checksig --nosignature --verbose "$stage/base.src.rpm"
rpm2cpio "$stage/base.src.rpm" > "$stage/base.cpio"
cpio -t --quiet < "$stage/base.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/base.cpio")
spec=$output/senemos-uke-linux-kernel-mainline.spec
native_archive=senemos-native-profile-7.3.1.tar.xz
boot_archive=senemos-uke-boot-recipe.tar.xz
find "$output" -maxdepth 1 -type f ! -name "${spec##*/}" \
 ! -name "$native_archive" ! -name "$boot_archive" ! -name boot-payload.json \
 -print0 | sort -z | xargs -0 sha256sum > "$stage/retained-sources.sha256"
for archive in "$native_archive" "$boot_archive"; do
    tar -tJf "$output/$archive" > "$stage/archive.entries"
    awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/archive.entries"
    tar -xJf "$output/$archive" -C "$stage/unpacked"
done
profile=$stage/unpacked/native-profile
boot=$stage/unpacked/boot-recipe
[[ $(cat "$profile/source-commit") == 0ad12c19b1f4ec56e7017348f41636f76925e4af ]]
jq -e '.kernel_release=="7.3.1-1303" and .binder_ipc_builtin and .binderfs_builtin and
 .touch_recovery_attempts_per_powered_epoch==1 and .native_memlat_groups==["llcc","l3"] and
 .panel_variants==["o82_36_02_0a","o82_42_02_0b"] and .touch_variants==["tianma","csot"]' \
 "$profile/source-composition.json" >/dev/null
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS)
cp "$profile/SHA256SUMS" "$stage/parent-profile.sha256"
cp "$boot/lock.json" "$stage/parent-boot-lock.json"
cmp "$profile/native.config" "$boot/packaging/native/native.config"
cmp "$boot/lock.json" "$output/boot-payload.json"
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --quiet -)
git -C "$profile" apply --check "$owner/packaging/native/ssc1303-prepare.patch"
git -C "$profile" apply "$owner/packaging/native/ssc1303-prepare.patch"
! grep -q '^CONFIG_IIO_UKE_SSC=' "$profile/native.config"
printf '\nCONFIG_IIO_UKE_SSC=m\n' >> "$profile/native.config"
install -m644 "$profile/native.config" "$boot/packaging/native/native.config"
printf 'prepare.sh\nnative.config\n' > "$stage/overlays"
cat "$owner/packaging/native/ssc1303-overlays.txt" >> "$stage/overlays"
printf 'packaging/native/native.config\n' > "$stage/boot-overlays"
config_hash=$(sha256sum "$profile/native.config"); config_hash=${config_hash%% *}
jq --arg hash "$config_hash" '(.source_assets[]|select(.path=="packaging/native/native.config")|.sha256)=$hash' \
 "$boot/lock.json" > "$stage/lock.json"
install -m644 "$stage/lock.json" "$boot/lock.json"
while read -r relative; do
    [[ $relative =~ ^(src|tests)/[a-zA-Z0-9_,./-]+$ && $relative != *..* ]]
    install -Dm644 "$owner/$relative" "$profile/$relative"
    if jq -e --arg path "$relative" '.source_assets[]|select(.path==$path)' "$boot/lock.json" >/dev/null; then
        install -Dm644 "$owner/$relative" "$boot/$relative"
        printf '%s\n' "$relative" >> "$stage/boot-overlays"
        hash=$(sha256sum "$boot/$relative"); hash=${hash%% *}
        jq --arg path "$relative" --arg hash "$hash" \
            '(.source_assets[]|select(.path==$path)|.sha256)=$hash' \
            "$boot/lock.json" > "$stage/lock.json"
        install -m644 "$stage/lock.json" "$boot/lock.json"
    fi
done < "$owner/packaging/native/ssc1303-overlays.txt"
while read -r expected relative; do
    relative=${relative#./}
    case $relative in source-commit|source-composition.json) continue;; esac
    if ! grep -Fxq -- "$relative" "$stage/overlays"; then
        printf '%s  %s\n' "$expected" "$profile/$relative" | sha256sum -c --quiet -
    fi
done < "$stage/parent-profile.sha256"
cmp <(jq -S 'del(.source_assets[].sha256)' "$stage/parent-boot-lock.json") \
    <(jq -S 'del(.source_assets[].sha256)' "$boot/lock.json")
while IFS=$'\t' read -r relative expected; do
    if ! grep -Fxq "$relative" "$stage/boot-overlays"; then
        printf '%s  %s\n' "$expected" "$boot/$relative" | sha256sum -c --quiet -
    fi
done < <(jq -r '.source_assets[]|[.path,.sha256]|@tsv' "$stage/parent-boot-lock.json")
cp "$profile/source-composition.json" "$profile/source-composition-before1400.json"
commit=$(git -C "$owner" rev-parse HEAD)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq -Rn '[inputs]' < "$stage/overlays" > "$stage/overlays.json"
jq --arg commit "$commit" --arg parent_hash "$parent_hash" --slurpfile overlays "$stage/overlays.json" '. + {
 source_commit:$commit,source_mode:"retained1303-with-native-ssc-iio",
 parent_copr_build:11251375,parent_srpm_sha256:$parent_hash,
 parent_source_commit:"0ad12c19b1f4ec56e7017348f41636f76925e4af",
 parent_header_sha256:"2400e59b76391a8337994ecde731634178a733712ee6c537bf3294f64bd1beef",
 parent_payload_sha256:"a5414d20fdbc0a20d8e3f055d959367a9c2b5de8ed8ba31f4e12dbaf476e9daa",
 parent_composition:"source-composition-before1400.json",kernel_release:"7.3.1-1400",rpm_revision:"1400",
 overlays:$overlays[0],kernel_driver_source_unchanged:false,
 native_ssc_iio_abi:1,ssc_service:400,ssc_service_version:1,ssc_service_instance:0,
 ssc_supported_datatypes:["accel","gyro","mag","ambient_light","ambient_light_back","proximity","sar"],
 ssc_unqualified_datatypes:["cct_front","flicker"],ssc_timestamp_source:"host-receipt",
 ssc_mount_matrix_inferred:false,firmware_payload_included:false,physical_acceptance:false
 }' "$profile/source-composition-before1400.json" > "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --quiet -)
for tree in native-profile boot-recipe; do
    archive=$native_archive
    [[ $tree != boot-recipe ]] || archive=$boot_archive
    tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner -cJf "$output/$archive" -C "$stage/unpacked" "$tree"
done
install -m644 "$boot/lock.json" "$output/boot-payload.json"
[[ $(grep -Fxc '%global senemos_build_release 1303' "$spec") == 1 ]]
[[ $(grep -Fxc 'Provides: uke-kernel(memlat-v1) = 1' "$spec") == 1 ]]
[[ $(grep -Fxc '%check' "$spec") == 1 ]]
awk '
 /^%global senemos_build_release 1303$/ {$0="%global senemos_build_release 1400"}
 /^Provides: uke-kernel\(memlat-v1\) = 1$/ {
  print;print "Provides: uke-kernel(ssc-iio-v1) = 1";next
 }
 /^%check$/ {
  print;print "bash native-profile/tests/ssc-package-contract.sh %{_uke_out}";next
 }
 /^%changelog$/ {
  print
  print "* Tue Nov 03 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-1400"
  print "- Bind firmware-owned Uke SSC sensors to the native QMI/IIO consumer."
  print "- Require exact API metadata and verify complete module linkage."
  print "- Retain supplier variants, MEMLAT, touch recovery and Binder support."
  print "";next
 }
 {print}
' "$spec" > "$stage/next.spec"
install -m644 "$stage/next.spec" "$spec"
sha256sum -c "$stage/retained-sources.sha256"
[[ $(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec") == 7.3.1-1400 ]]
