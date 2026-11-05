#!/usr/bin/env bash
# COPR/source only: retain cumulative inputs and stage early SSC indications.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
profile=$(realpath "${1:?Pass the complete native profile}")
boot=$(realpath "${2:?Pass the complete boot recipe}")
manifest=manifests/ssc-early-layer-v2-20261105.json
(cd "$owner"; jq -r '.assets[]|.sha256+"  "+.path' "$manifest" | sha256sum -c --strict --quiet -)
(cd "$profile"; sha256sum -c --strict --quiet SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --strict --quiet -)
jq -e '.package_family=="senemos-uke-linux-kernel-mainline-unstable" and
 (.source_commit=="bba194e74ab97dcb848887fa62430c20f9d755d9" or
 .source_commit=="45d8355e366e6b75e43f441ca99b517302adf522") and
 .ssc_observation_abi==1 and .camcc_probe_observation_abi==1 and
 .qualified_touch_layer==1 and .queued_kernel_layer==1 and .o82_memory_layer==1 and
 .gmu_irq_owned_acknowledgement==true and .o82_private_color_bundle_version==5 and
 .o82_color_initial_preset=="" and .o82_color_dma_enabled==false and
 .native_hdr_advertised==false and (.ssc_transaction_layer==1 and .ssc_qmi_transaction_id_returns_id==true) and
 ((.ssc_early_sample_layer // 0)==0 or .ssc_early_sample_layer==2)' \
 "$profile/source-composition.json" >/dev/null
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
mapfile -t paths < <(jq -r '.assets[].path' "$owner/$manifest"; printf '%s\n' "$manifest")
if [[ $(jq -r '.ssc_early_sample_layer // 0' "$profile/source-composition.json") == 2 ]]; then
    for path in "${paths[@]}"; do
        for tree in "$profile" "$boot"; do
            [[ -f $tree/$path && ! -L $tree/$path ]]
            cmp "$owner/$path" "$tree/$path"
        done
        digest=$(sha256sum "$owner/$path"); digest=${digest%% *}
        jq -e --arg path "$path" --arg sha "$digest" \
          'any(.source_assets[];.path==$path and .sha256==$sha)' "$boot/lock.json" >/dev/null
    done
    jq -e '.ssc_early_sample_requires_ack==true and .ssc_early_sample_physical_acceptance==false and
      .ssc_early_sample_layer_manifest=="manifests/ssc-early-layer-v2-20261105.json"' \
      "$profile/source-composition.json" >/dev/null
    printf 'SSC early-indication source layer already exact; no mutation\n'
    exit 0
fi
# Admit every affected preimage in both trees before modifying either tree.
for tree in "$profile" "$boot"; do
    while IFS=$'\t' read -r path digest; do
        [[ -f $tree/$path && ! -L $tree/$path ]]
        printf '%s  %s\n' "$digest" "$tree/$path" | sha256sum -c --strict --quiet -
    done < <(jq -r '.preimages[]|[.path,.sha256]|@tsv' "$owner/$manifest")
    for path in "${paths[@]}"; do
        if ! jq -e --arg path "$path" 'any(.preimages[];.path==$path)' "$owner/$manifest" >/dev/null; then
            [[ ! -e $tree/$path && ! -L $tree/$path ]]
        fi
    done
done
cp "$profile/source-composition.json" "$stage/composition.json"
cp "$boot/lock.json" "$stage/lock.json"
for role in profile boot; do
    tree=$profile
    [[ $role != boot ]] || tree=$boot
    (cd "$tree"; find . -type f ! -name SHA256SUMS ! -name source-composition.json ! -name lock.json -print0 |
      sort -z | xargs -0 sha256sum) > "$stage/$role.before"
done
for path in "${paths[@]}"; do
    install -Dm644 "$owner/$path" "$profile/$path"
    install -Dm644 "$owner/$path" "$boot/$path"
    digest=$(sha256sum "$owner/$path"); digest=${digest%% *}
    jq --arg path "$path" --arg sha "$digest" '
      if any(.source_assets[];.path==$path) then
        (.source_assets[]|select(.path==$path)|.sha256)=$sha
      else .source_assets += [{path:$path,sha256:$sha}] end' "$boot/lock.json" > "$stage/next.lock"
    install -m644 "$stage/next.lock" "$boot/lock.json"
done
jq '. + {ssc_early_sample_layer:2,ssc_early_sample_requires_ack:true,
 ssc_early_sample_layer_manifest:"manifests/ssc-early-layer-v2-20261105.json",
 ssc_early_sample_physical_acceptance:false}' "$stage/composition.json" > "$stage/next.composition"
install -m644 "$stage/next.composition" "$profile/source-composition.json"
for doc in "$stage/composition.json" "$profile/source-composition.json"; do
    jq -S 'del(.ssc_early_sample_layer,.ssc_early_sample_requires_ack,
      .ssc_early_sample_layer_manifest,.ssc_early_sample_physical_acceptance)' "$doc" > "$stage/$(basename "$doc").retained"
done
cmp "$stage/composition.json.retained" "$stage/source-composition.json.retained"
for role in profile boot; do
    tree=$profile
    [[ $role != boot ]] || tree=$boot
    while read -r digest path; do
        path=${path#./}
        if jq -e --arg path "$path" 'any(.preimages[];.path==$path)' "$owner/$manifest" >/dev/null; then continue; fi
        printf '%s  %s\n' "$digest" "$tree/$path" | sha256sum -c --strict --quiet -
    done < "$stage/$role.before"
done
# Preserve every pre-existing lock record and its extra fields; only declared
# imported paths may change their content digest. No original record is lost.
jq -S --slurpfile layer "$owner/$manifest" '
 .source_assets |= map(if .path as $path | any($layer[0].assets[];.path==$path)
 then .sha256="declared-source-change" else . end)' "$stage/lock.json" > "$stage/old.normalized"
jq -S --slurpfile old "$stage/lock.json" --slurpfile layer "$owner/$manifest" '
 .source_assets |= map(select(.path as $path | any($old[0].source_assets[];.path==$path))) |
 .source_assets |= map(if .path as $path | any($layer[0].assets[];.path==$path)
 then .sha256="declared-source-change" else . end)' "$boot/lock.json" > "$stage/new.normalized"
cmp "$stage/old.normalized" "$stage/new.normalized"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
printf 'SSC early-indication source layer: bounded indication staging and actual-callback fixtures; all other source/config/boot/gates retained\n'
