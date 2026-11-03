#!/usr/bin/env bash
# Host-only stock image inspection; sourced by senemos.sh. No donor tool runs.
set -Eeuo pipefail
stock_u32() { od -An -v --endian="$3" -tu4 -j "$2" -N4 "$1" | tr -d '[:space:]'; }
stock_extract() {
    local vendor=$1 overlay=$2 out=$3 bytes page header ramdisk dtbytes offset cursor size count=0
    mkdir -p "$out"
    [[ $(head -c 8 "$vendor") == VNDRBOOT ]] || die 'Invalid vendor_boot magic'
    [[ $(stock_u32 "$vendor" 8 little) == 4 ]] || die 'Only reviewed Android vendor_boot v4 is supported'
    page=$(stock_u32 "$vendor" 12 little)
    header=$(stock_u32 "$vendor" 2096 little)
    ramdisk=$(stock_u32 "$vendor" 24 little)
    dtbytes=$(stock_u32 "$vendor" 2100 little)
    bytes=$(stat -c %s "$vendor")
    [[ $page == 4096 && $header == 2128 ]] || die 'Unexpected vendor_boot page/header size'
    ((dtbytes >= 40 && dtbytes <= 16777216 && ramdisk <= bytes)) || die 'Invalid vendor_boot section size'
    offset=$(((header + page - 1) / page * page + (ramdisk + page - 1) / page * page))
    ((offset <= bytes && dtbytes <= bytes - offset)) || die 'Truncated vendor_boot DTB section'
    dd if="$vendor" of="$out/vendor-dtb.bin" iflag=skip_bytes,count_bytes skip="$offset" count="$dtbytes" status=none
    cursor=0
    while ((cursor < dtbytes)); do
        ((dtbytes - cursor >= 40 && count < 16)) || die 'Invalid concatenated DTB section'
        [[ $(stock_u32 "$out/vendor-dtb.bin" "$cursor" big) == 3490578157 ]] || die 'Invalid concatenated FDT magic'
        size=$(stock_u32 "$out/vendor-dtb.bin" "$((cursor + 4))" big)
        ((size >= 40 && size <= dtbytes - cursor)) || die 'Truncated concatenated FDT'
        dd if="$out/vendor-dtb.bin" of="$out/base-$count.dtb" iflag=skip_bytes,count_bytes skip="$cursor" count="$size" status=none
        dtc -q -I dtb -O dtb -o /dev/null "$out/base-$count.dtb"
        count=$((count + 1)); cursor=$((cursor + size))
    done
    local total table_header entry_size entries entries_offset version i entry dt_size dt_offset
    [[ $(stock_u32 "$overlay" 0 big) == 3619138334 ]] || die 'Invalid Android DT table magic'
    total=$(stock_u32 "$overlay" 4 big)
    table_header=$(stock_u32 "$overlay" 8 big)
    entry_size=$(stock_u32 "$overlay" 12 big)
    entries=$(stock_u32 "$overlay" 16 big)
    entries_offset=$(stock_u32 "$overlay" 20 big)
    version=$(stock_u32 "$overlay" 28 big)
    ((total <= $(stat -c %s "$overlay") && total >= 32 && table_header == 32 && entry_size == 32 && entries > 0 && entries <= 16 && version == 0)) || die 'Unsupported or truncated DT table'
    ((entries_offset >= table_header && entries_offset + entry_size * entries <= total)) || die 'Invalid DT table entries'
    for ((i=0; i<entries; ++i)); do
        entry=$((entries_offset + i * entry_size))
        dt_size=$(stock_u32 "$overlay" "$entry" big)
        dt_offset=$(stock_u32 "$overlay" "$((entry + 4))" big)
        ((dt_size >= 40 && dt_offset >= entries_offset + entry_size * entries && dt_offset <= total && dt_size <= total - dt_offset)) || die 'DT table payload outside declared bounds'
        dd if="$overlay" of="$out/overlay-$i.dtbo" iflag=skip_bytes,count_bytes skip="$dt_offset" count="$dt_size" status=none
        dtc -q -I dtb -O dtb -o /dev/null "$out/overlay-$i.dtbo"
    done
    fdtget -t s "$out/overlay-0.dtbo" / model | grep -F Uke >/dev/null || die 'Overlay does not identify an Uke board'
    # All alternatives are inventoried. Never infer a selected index from SoC naming.
    printf 'index\tbase_sha256\tmerged_sha256\tmsm_id_cells\n' > "$out/dtb-inventory.tsv"
    for ((i=0; i<count; ++i)); do
        fdtoverlay -i "$out/base-$i.dtb" -o "$out/merged-$i.dtb" "$out/overlay-0.dtbo"
        dtc -q -I dtb -O dts -o "$out/merged-$i.dts" "$out/merged-$i.dtb"
        printf '%s\t%s\t%s\t%s\n' "$i" "$(sha256sum "$out/base-$i.dtb" | cut -d ' ' -f1)" "$(sha256sum "$out/merged-$i.dtb" | cut -d ' ' -f1)" "$(fdtget -t x "$out/base-$i.dtb" / qcom,msm-id)" >> "$out/dtb-inventory.tsv"
    done
    jq -n --argjson bases "$count" --argjson overlays "$entries" \
        '{base_dtb_count:$bases,overlay_count:$overlays,merged_with_overlay_index:0,overlay_root_metadata_applied:false,selected_dtb_index:null,own_device_profile_matched:false,bootloader_memory_fixups_present:false,boot_tested:false,hardware_tested:false}' > "$out/inspection.json"
}
stock_dt_main() {
    local vendor='' overlay='' profile='' key value engine arch recipe image dest file
    while (($#)); do
        case $1 in
            --vendor-boot|--dtbo|--firmware-profile) key=$1; shift; (($#)) || die "Missing value for $key"; value=$1;;
            *) die 'Stock inspection requires --vendor-boot FILE --dtbo FILE --firmware-profile NAME';;
        esac
        case $key in --vendor-boot) vendor=$value;; --dtbo) overlay=$value;; --firmware-profile) profile=$value;; esac
        shift
    done
    [[ $profile =~ ^[a-z0-9][a-z0-9._-]{0,79}$ && -f $vendor && -f $overlay ]] || die 'Stock profile or regular-file inputs are missing'
    for file in "$vendor" "$overlay"; do
        [[ ! -L $file && $(stat -c %s "$file") -ge 2128 && $(stat -c %s "$file") -le 134217728 ]] || die 'Stock inputs must be bounded regular files'
    done
    bootstrap
    # shellcheck disable=SC2153 # Set by the sourcing senemos.sh bootstrap.
    engine=$ENGINE; arch=$(uname -m)
    [[ $arch == x86_64 || $arch == aarch64 ]] || die 'Unsupported stock inspection host'
    recipe=$(cat "$KERNEL/configs/host/Containerfile.rawhide" "$RULES" | sha256sum | cut -d ' ' -f1)
    case $arch in x86_64) arch=amd64;; aarch64) arch=arm64;; esac
    image=localhost/senemos-uke-build:rawhide-$arch-${recipe:0:16}
    "$engine" image inspect "$image" >/dev/null 2>&1 || die 'Run a kernel build once to prepare the pinned host toolchain'
    dest=$KERNEL/referances/firmware/$profile
    [[ ! -e $dest ]] || die 'Stock inspection output already exists; preserve it and choose a new profile receipt name'
    mkdir -p "$dest/raw" "$dest/derived"
    cp --reflink=auto "$vendor" "$dest/raw/vendor_boot.img"
    cp --reflink=auto "$overlay" "$dest/raw/dtbo.img"
    (cd "$dest/raw"; sha256sum vendor_boot.img dtbo.img > SHA256SUMS)
    local -a owner
    if [[ $engine == podman ]]; then owner=(--userns=keep-id); else owner=(--user "$(id -u):$(id -g)"); fi
    "$engine" run --rm --network=none --security-opt label=disable --cpus=1 "${owner[@]}" \
        -v "$KERNEL:/work/kernel:ro" -v "$dest:/input" "$image" \
        bash -c 'source /work/kernel/src/boot/stock-dt.sh; die() { printf "%s\n" "$*" >&2; exit 1; }; stock_extract /input/raw/vendor_boot.img /input/raw/dtbo.img /input/derived' \
        > "$dest/inspection.log" 2>&1 || die 'Stock DT inspection failed; retained its input and diagnostics'
    jq --arg profile "$profile" --arg vendor "$(sha256sum "$dest/raw/vendor_boot.img" | cut -d ' ' -f1)" \
        --arg overlay "$(sha256sum "$dest/raw/dtbo.img" | cut -d ' ' -f1)" \
        '. + {schema_version:1,scope:"stock-package-static-inspection",firmware_profile:$profile,vendor_boot_sha256:$vendor,dtbo_sha256:$overlay}' \
        "$dest/derived/inspection.json" > "$dest/manifest.json"
    say "Stock DT evidence prepared for $profile; exact installed-device selection and RAM fixups remain unverified"
}
