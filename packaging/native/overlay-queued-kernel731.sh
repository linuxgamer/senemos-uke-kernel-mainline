#!/usr/bin/env bash
# COPR/source only: retain the complete memory/v5 profile and all boot assets.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
profile=$(realpath "${1:?Pass the native profile}")
boot=$(realpath "${2:?Pass the boot recipe}")
spec=$(realpath "${3:?Pass the complete unstable production spec}")
manifest=manifests/queued-kernel-layer-20261105.json
hook='bash native-profile/packaging/native/prepare-queued-kernel731.sh "$PWD" native-profile'
(cd "$profile"; sha256sum -c --strict --quiet SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --strict --quiet -)
jq -e '.package_family=="senemos-uke-linux-kernel-mainline-unstable" and
 .o82_memory_layer==1 and .qualified_touch_layer==1 and
 .o82_private_color_bundle_version==5 and .o82_lutbus_max_bytes==41488 and
 .o82_memory_software_support==true and .o82_memory_protection_software_support==true and
 .o82_explicit_neutral_memory==true and .nfc_wakeup_owner=="i2c-core" and
 .camcc_probe_observation_abi==1 and .ssc_observation_abi==1 and
 .o82_color_initial_preset=="" and .o82_color_dma_enabled==false and
 .native_hdr_advertised==false and
 ((.queued_kernel_layer // 0)==0 or .queued_kernel_layer==1) and
 ((has("camera_geometry_source")|not) or .camera_geometry_source=="9398700a6375a309f572d588a9e448cdbc4b0736")' \
 "$profile/source-composition.json" >/dev/null
grep -Fxq 'Name: senemos-uke-linux-kernel-mainline-unstable' "$spec"
[[ $(grep -c '^%build$' "$spec") == 1 && $(grep -c '^%prep$' "$spec") == 1 ]]
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
mkdir "$work/assets"
while IFS=$'\t' read -r path digest; do
    printf '%s  %s\n' "$digest" "$owner/$path" | sha256sum -c --strict --quiet -
    install -Dm644 "$owner/$path" "$work/assets/$path"
done < <(jq -r '.owned_assets[]|[.path,.sha256]|@tsv' "$owner/$manifest")
while IFS=$'\t' read -r commit path digest; do
    git -C "$owner" cat-file -e "$commit^{commit}" 2>/dev/null || git -C "$owner" fetch --depth=1 origin "$commit"
    mkdir -p "$work/assets/$(dirname "$path")"
    git -C "$owner" show "$commit:$path" > "$work/assets/$path"
    printf '%s  %s\n' "$digest" "$work/assets/$path" | sha256sum -c --strict --quiet -
done < <(jq -r '.imports[]|[.commit,.path,.sha256]|@tsv' "$owner/$manifest")
install -Dm644 "$owner/$manifest" "$work/assets/$manifest"
mapfile -t assets < <(cd "$work/assets"; find . -type f -printf '%P\n' | sort)
verify_assets()
{
    local tree=$1 path
    for path in "${assets[@]}"; do cmp "$work/assets/$path" "$tree/$path"; done
}
verify_boot_records()
{
    local path digest
    for path in "${assets[@]}"; do
        digest=$(sha256sum "$work/assets/$path" | cut -d ' ' -f1)
        jq -e --arg path "$path" --arg sha "$digest" \
          'any(.source_assets[];.path==$path and .sha256==$sha)' "$boot/lock.json" >/dev/null
    done
}
verify_hook()
{
    [[ $(grep -Fxc "$hook" "$spec") == 1 ]]
    QUEUED_PREP_HOOK="$hook" awk 'BEGIN {hook=ENVIRON["QUEUED_PREP_HOOK"]}
      $0==hook {getline;if($0!="%build")exit 1;found++}
      END {if(found!=1)exit 1}' "$spec"
}
if [[ $(jq -r '.queued_kernel_layer // 0' "$profile/source-composition.json") == 1 ]]; then
    verify_assets "$profile"
    verify_assets "$boot"
    verify_boot_records
    verify_hook
    jq -e '.gmu_irq_owned_acknowledgement==true and .gmu_irq_reference_check==11261228 and
      .gmu_irq_reference_source=="a85f0f660dd947d2737dca18ce043674ce55a45e" and
      .camera_geometry_three_argument_pad_api==true and .camera_geometry_private_mutex_and_per_file_try==true and
      .queued_kernel_layer_manifest=="manifests/queued-kernel-layer-20261105.json" and
      .camera_geometry_physical_acceptance==false and .gmu_msm_physical_acceptance==false' \
      "$profile/source-composition.json" >/dev/null
    printf 'Queued source layer already exact; no mutation\n'
    exit 0
fi
! grep -Fq prepare-queued-kernel731.sh "$spec"
for tree in "$profile" "$boot"; do
    for path in "${assets[@]}"; do
        if [[ -e $tree/$path || -L $tree/$path ]]; then
            [[ -f $tree/$path && ! -L $tree/$path ]]
            cmp "$work/assets/$path" "$tree/$path"
        fi
    done
done
cp "$profile/source-composition.json" "$work/composition.json"
cp "$boot/lock.json" "$work/lock.json"
cp "$spec" "$work/original.spec"
(cd "$profile"; find . -type f ! -name SHA256SUMS ! -name source-composition.json -print0 | sort -z | xargs -0 sha256sum) > "$work/profile.before"
(cd "$boot"; find . -type f ! -name lock.json -print0 | sort -z | xargs -0 sha256sum) > "$work/boot.before"
QUEUED_PREP_HOOK="$hook" awk 'BEGIN {hook=ENVIRON["QUEUED_PREP_HOOK"]}
 /^%build$/ {print hook;found++} {print}
 END {if(found!=1)exit 1}' "$spec" > "$work/next.spec"
QUEUED_PREP_HOOK="$hook" awk 'BEGIN {hook=ENVIRON["QUEUED_PREP_HOOK"]}
 $0!=hook {print}' "$work/next.spec" > "$work/restored.spec"
cmp "$work/original.spec" "$work/restored.spec"
for path in "${assets[@]}"; do
    install -Dm644 "$work/assets/$path" "$profile/$path"
    install -Dm644 "$work/assets/$path" "$boot/$path"
    digest=$(sha256sum "$work/assets/$path" | cut -d ' ' -f1)
    jq --arg path "$path" --arg sha "$digest" '
      if any(.source_assets[];.path==$path) then
        if any(.source_assets[];.path==$path and .sha256!=$sha) then error("Unexpected existing boot asset") else . end
      else .source_assets += [{path:$path,sha256:$sha}] end' "$boot/lock.json" > "$work/next.lock"
    install -m644 "$work/next.lock" "$boot/lock.json"
done
jq '. + {queued_kernel_layer:1,queued_kernel_layer_manifest:"manifests/queued-kernel-layer-20261105.json",
 camera_geometry_source:"9398700a6375a309f572d588a9e448cdbc4b0736",camera_geometry_check:11261165,
 camera_geometry_three_argument_pad_api:true,camera_geometry_private_mutex_and_per_file_try:true,
 camera_geometry_physical_acceptance:false,gmu_irq_reference_source:"a85f0f660dd947d2737dca18ce043674ce55a45e",
 gmu_irq_reference_check:11261228,gmu_irq_owned_acknowledgement:true,gmu_msm_physical_acceptance:false}' \
 "$work/composition.json" > "$work/next.composition"
install -m644 "$work/next.composition" "$profile/source-composition.json"
for document in "$work/composition.json" "$profile/source-composition.json"; do
    jq -S 'del(.queued_kernel_layer,.queued_kernel_layer_manifest,
      .camera_geometry_source,.camera_geometry_check,.camera_geometry_three_argument_pad_api,
      .camera_geometry_private_mutex_and_per_file_try,.camera_geometry_physical_acceptance,
      .gmu_irq_reference_source,.gmu_irq_reference_check,.gmu_irq_owned_acknowledgement,
      .gmu_msm_physical_acceptance)' "$document" > "$work/$(basename "$document").retained"
done
cmp "$work/composition.json.retained" "$work/source-composition.json.retained"
(cd "$profile"; sha256sum -c --strict --quiet "$work/profile.before")
(cd "$boot"; sha256sum -c --strict --quiet "$work/boot.before")
cmp <(jq -S 'del(.source_assets)' "$work/lock.json") <(jq -S 'del(.source_assets)' "$boot/lock.json")
# Every original asset entry, including any extra metadata, remains present.
jq -e --slurpfile old "$work/lock.json" '.source_assets as $new|
 all($old[0].source_assets[];. as $entry|any($new[];.==$entry)) and
 ([.source_assets[].path]|length== (unique|length))' "$boot/lock.json" >/dev/null
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
install -m644 "$work/next.spec" "$spec"
verify_assets "$profile"
verify_assets "$boot"
verify_boot_records
verify_hook
printf 'Queued source layer: qualified geometry/GMU assets and one prep entry; all existing profile/boot source bytes retained\n'
