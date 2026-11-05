#!/usr/bin/env bash
# Source/COPR only: retain the complete12204 profile and boot recipe.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
profile=$(realpath "${1:?Complete native profile}")
boot=$(realpath "${2:?Complete boot recipe}")
manifest=$owner/manifests/ssc-sip1328-als-layer-20261105.json
(cd "$owner"; jq -r '.assets[]|.sha256+"  "+.path' "$manifest" | sha256sum -c --strict --quiet -)
(cd "$profile"; sha256sum -c --strict --quiet SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --strict --quiet -)
jq -e '.source_commit=="de1bdf9ab531d772a8c02847c51b01ed4ffcd42f" and
 .package_family=="senemos-uke-linux-kernel-mainline-unstable" and
 .ssc_early_sample_layer==2 and .ssc_early_sample_requires_ack and
 .ssc_stk3bcx_als_layer==1 and .ssc_stk3bcx_als_shapes==[2,6] and
 .ssc_stk3bcx_als_physical_acceptance==false and
 .governor_options_layer==1 and .camera_gcc_config_layer==1 and
 .all_existing_features_retained and (.native_hdr_advertised|not) and
 (.o82_color_dma_enabled|not) and (.speaker_protection_graph_admitted|not) and
 ((.ssc_sip1328_als_layer//0)==0 or .ssc_sip1328_als_layer==1)' \
 "$profile/source-composition.json" >/dev/null
path=src/sensors/uke-ssc-iio.c
before=$(jq -er .before_sha256 "$manifest")
after=$(jq -er .after_sha256 "$manifest")
layer=$(jq -r '.ssc_sip1328_als_layer//0' "$profile/source-composition.json")
for tree in "$profile" "$boot"; do
    [[ -f $tree/$path && ! -L $tree/$path ]]
    expected=$before
    [[ $layer != 1 ]] || expected=$after
    printf '%s  %s\n' "$expected" "$tree/$path" | sha256sum -c --strict --quiet -
done
if [[ $layer == 1 ]]; then
    jq -e '.ssc_sip1328_als_shapes==[2,6] and
      .ssc_sip1328_als_layer_manifest=="manifests/ssc-sip1328-als-layer-20261105.json" and
      (.ssc_sip1328_als_physical_acceptance|not)' "$profile/source-composition.json" >/dev/null
    printf 'SIP1328 logical rear ALS source layer already exact; no mutation\n'
    exit 0
fi
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
mkdir -p "$stage/src/sensors"
install -m644 "$profile/$path" "$stage/$path"
(cd "$stage"; patch -p1 --fuzz=0 --batch -i "$owner/src/sensors/0002-ssc-sip1328-rear-als.patch")
printf '%s  %s\n' "$after" "$stage/$path" | sha256sum -c --strict --quiet -
cp "$profile/source-composition.json" "$stage/old.composition"
cp "$boot/lock.json" "$stage/old.lock"
jq '.+{ssc_sip1328_als_layer:1,ssc_sip1328_als_shapes:[2,6],
 ssc_sip1328_als_layer_manifest:"manifests/ssc-sip1328-als-layer-20261105.json",
 ssc_sip1328_als_physical_acceptance:false}' "$stage/old.composition" > "$stage/new.composition"
jq --arg path "$path" --arg sha "$after" '
 if any(.source_assets[];.path==$path) then
 (.source_assets[]|select(.path==$path)|.sha256)=$sha else error("Missing original SSC lock record") end' \
 "$stage/old.lock" > "$stage/new.lock"
for tree in "$profile" "$boot"; do
    install -m644 "$stage/$path" "$tree/$path"
done
install -m644 "$stage/new.composition" "$profile/source-composition.json"
install -m644 "$stage/new.lock" "$boot/lock.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
printf 'SIP1328 rear ALS: named logical endpoint, exact2/6 shapes; other physical/API/stream/config/DT/firmware/admission retained\n'
