#!/usr/bin/env bash
# COPR source preparation only; retain cumulative source/config/boot admission.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
[[ $# == 2 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
profile=$(realpath "$1")
boot=$(realpath "$2")
manifest=manifests/o82-memory-layer-20261105.json
(cd "$owner"; jq -r '.imports[]|.sha256+"  "+.path' "$manifest" | sha256sum -c --strict --quiet -)
(cd "$profile"; sha256sum -c --strict --quiet SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --strict --quiet -)
jq -e '.package_family=="senemos-uke-linux-kernel-mainline-unstable" and
 .camcc_probe_observation_abi==1 and .ssc_observation_abi==1 and
 .nfc_wakeup_owner=="i2c-core" and .o82_hsic_software_support and
 .o82_sixzone_software_support and .o82_color_initial_preset=="" and
 .native_hdr_advertised==false' "$profile/source-composition.json" >/dev/null
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
verify_after()
{
    local tree=$1 role=$2 relative digest
    while IFS=$'\t' read -r relative digest; do
        if [[ ! -e $tree/$relative ]]; then [[ $role == boot ]] || return 1; continue; fi
        printf '%s  %s\n' "$digest" "$tree/$relative" | sha256sum -c --strict --quiet -
    done < <(jq -r '.imports[]|[.path,.sha256]|@tsv' "$owner/$manifest")
}
if [[ $(jq -r '.o82_memory_layer // 0' "$profile/source-composition.json") == 1 ]]; then
    verify_after "$profile" profile
    verify_after "$boot" boot
    cmp "$owner/$manifest" "$profile/$manifest"
    cmp "$owner/packaging/native/overlay-o82-memory731.sh" "$profile/packaging/native/overlay-o82-memory731.sh"
    while read -r relative; do
        [[ $relative =~ ^(src|tests|manifests|packaging)/[a-zA-Z0-9_./-]+$ && $relative != *..* ]]
        test -f "$boot/$relative"
        jq -e --arg path "$relative" 'any(.source_assets[];.path==$path)' "$boot/lock.json" >/dev/null
    done < <(jq -r '.o82_memory_boot_mirrors[]' "$profile/source-composition.json")
    jq -e '.o82_private_color_bundle_version==5 and .o82_lutbus_max_bytes==41488 and
      .o82_color_bundle_loader_versions==[4,5] and .o82_memory_software_support and
      .o82_memory_protection_software_support and .o82_explicit_neutral_memory' \
      "$profile/source-composition.json" >/dev/null
    printf 'O82 memory/v5 source layer already present; exact assets retained\n'
    exit 0
fi
jq -e '.o82_private_color_bundle_version==4 and .o82_lutbus_max_bytes==41320' \
    "$profile/source-composition.json" >/dev/null
history=source-composition-before-o82-memory-v5.json
test ! -e "$profile/$history"
# Admit every affected preimage before changing either source tree.
for role in profile boot; do
    tree=$profile
    [[ $role != boot ]] || tree=$boot
    needs_header=false
    while IFS=$'\t' read -r relative before; do
        [[ $relative =~ ^(src/display|tests)/[a-zA-Z0-9_.-]+$ && $relative != *..* ]]
        if [[ $before == absent ]]; then test ! -e "$tree/$relative"; continue; fi
        if [[ ! -e $tree/$relative ]]; then [[ $role == boot ]] || exit 1; continue; fi
        printf '%s  %s\n' "$before" "$tree/$relative" | sha256sum -c --strict --quiet -
        needs_header=true
    done < <(jq -r '.imports[]|[.path,(.before_sha256 // "absent")]|@tsv' "$owner/$manifest")
    if [[ $role == profile ]] || $needs_header; then
        test ! -e "$tree/$manifest"
        test ! -e "$tree/packaging/native/overlay-o82-memory731.sh"
    fi
done
cp "$profile/source-composition.json" "$stage/composition.json"
cp "$profile/SHA256SUMS" "$stage/profile.sha256"
cp "$boot/lock.json" "$stage/boot-lock.json"
(cd "$boot"; find . -type f ! -name lock.json -print0 | sort -z | xargs -0 sha256sum) > "$stage/boot.sha256"
for role in profile boot; do
    tree=$profile
    [[ $role != boot ]] || tree=$boot
    : > "$stage/$role-changed"
    needs_header=false
    while IFS=$'\t' read -r relative before; do
        [[ $relative =~ ^(src/display|tests)/[a-zA-Z0-9_.-]+$ && $relative != *..* ]]
        if [[ $before == absent ]]; then continue; fi
        if [[ ! -e $tree/$relative ]]; then [[ $role == boot ]] || exit 1; continue; fi
        printf '%s  %s\n' "$before" "$tree/$relative" | sha256sum -c --strict --quiet -
        needs_header=true
        install -m644 "$owner/$relative" "$tree/$relative"
        printf '%s\n' "$relative" >> "$stage/$role-changed"
    done < <(jq -r '.imports[]|[.path,(.before_sha256 // "absent")]|@tsv' "$owner/$manifest")
    if $needs_header; then
        relative=src/display/o82-memory-format.h
        test ! -e "$tree/$relative"
        install -Dm644 "$owner/$relative" "$tree/$relative"
        printf '%s\n' "$relative" >> "$stage/$role-changed"
    fi
    if [[ $role == profile ]] || $needs_header; then
        for relative in "$manifest" packaging/native/overlay-o82-memory731.sh; do
            test ! -e "$tree/$relative"
            install -Dm644 "$owner/$relative" "$tree/$relative"
            printf '%s\n' "$relative" >> "$stage/$role-changed"
        done
    fi
    verify_after "$tree" "$role"
done
while read -r relative; do
    digest=$(sha256sum "$boot/$relative"); digest=${digest%% *}
    jq --arg path "$relative" --arg digest "$digest" '
      if any(.source_assets[];.path==$path) then
        (.source_assets[]|select(.path==$path)|.sha256)=$digest
      else .source_assets += [{path:$path,sha256:$digest}] end' \
      "$boot/lock.json" > "$stage/lock.json"
    install -m644 "$stage/lock.json" "$boot/lock.json"
done < "$stage/boot-changed"
for role in profile boot; do
    tree=$profile receipt=$stage/profile.sha256
    [[ $role != boot ]] || { tree=$boot; receipt=$stage/boot.sha256; }
    while read -r expected relative; do
        relative=${relative#./}
        if [[ $role == profile && $relative == source-composition.json ]]; then continue; fi
        if ! grep -Fxq "$relative" "$stage/$role-changed"; then
            printf '%s  %s\n' "$expected" "$tree/$relative" | sha256sum -c --strict --quiet -
        fi
    done < "$receipt"
done
cmp <(jq -S 'del(.source_assets)' "$stage/boot-lock.json") <(jq -S 'del(.source_assets)' "$boot/lock.json")
jq -e --slurpfile old "$stage/boot-lock.json" --rawfile changed "$stage/boot-changed" '
 ($changed|split("\n")|map(select(length>0))) as $allowed |
 [.source_assets[].path] as $paths |
 all($old[0].source_assets[];.path as $p|$paths|index($p)!=null) and
 all(.source_assets[];.path as $p|any($old[0].source_assets[];.path==$p) or ($allowed|index($p)!=null)) and
 ((.source_assets|map(.path)|length)==(.source_assets|map(.path)|unique|length))' "$boot/lock.json" >/dev/null
cp "$stage/composition.json" "$profile/$history"
producer=$(git -C "$owner" rev-parse HEAD)
jq --arg history "$history" --arg producer "$producer" --rawfile changed "$stage/profile-changed" \
 --rawfile mirrors "$stage/boot-changed" '
 . + {source_mode:(.source_mode+"-with-o82-memory-v5"),
 o82_memory_layer:1,o82_memory_layer_producer:$producer,o82_memory_parent_composition:$history,
 o82_memory_source_manifest:"manifests/o82-memory-layer-20261105.json",
 o82_memory_boot_mirrors:($mirrors|split("\n")|map(select(length>0))),
 o82_memory_software_support:true,o82_memory_protection_software_support:true,
 o82_explicit_neutral_memory:true,o82_color_bundle_loader_versions:[4,5],
 o82_private_color_bundle_version:5,o82_lutbus_max_bytes:41488,
 qualified_o82_profile_utility_check:11261174,
 qualified_o82_profile_utility_source:"8bf314f6aac5249781e9fc2c95fd6b8448d7d75b",
 o82_after_reference_changes:((.o82_after_reference_changes+[
   "memory/protection programming and strict v5 payload routing"] )|unique),
 o82_atomic_additional_kernel_files:((.o82_atomic_additional_kernel_files+[
   "drivers/gpu/drm/msm/disp/dpu1/o82-memory-format.h"] )|unique),
 overlays:((.overlays+($changed|split("\n")|map(select(length>0))))|unique)}' \
 "$stage/composition.json" > "$profile/source-composition.json"
jq -e --slurpfile old "$stage/composition.json" '
 . as $current | ["source_mode","overlays","o82_private_color_bundle_version",
 "o82_lutbus_max_bytes","qualified_o82_profile_utility_check","qualified_o82_profile_utility_source",
 "o82_after_reference_changes","o82_atomic_additional_kernel_files"] as $allowed |
 all($old[0]|to_entries[];.key as $k|($allowed|index($k)!=null) or $current[$k]==.value) and
 all($old[0].overlays[];. as $p|$current.overlays|index($p)!=null)' "$profile/source-composition.json" >/dev/null
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --strict --quiet -)
printf 'O82 memory/v5 source layer applied; undeclared source/config/boot and admission state retained\n'
