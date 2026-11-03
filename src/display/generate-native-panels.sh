#!/usr/bin/env bash
# Compile supplier-specific overlays into one early-entry selection table.
set -Eeuo pipefail
[[ $# -ge 4 && -d $1 && -d $2 && -f $3 && $4 =~ ^(36|42|auto)$ ]] || exit 2
kernel=$(realpath "$1") output=$(realpath "$2") source=$(realpath "$3") selection=$4
shift 4
variants=("$selection")
[[ $selection != auto ]] || variants=(36 42)
header=$output/uke-native-display.h
: > "$header"
for variant in "${variants[@]}"; do
    cpp -nostdinc -undef -D__DTS__ -DO82_PANEL_VARIANT="$variant" -x assembler-with-cpp \
        "$@" -I "$kernel/include" "$source" > "$output/display-$variant.dts"
    if [[ -n ${UKE_NATIVE_VIDEO_SOURCE:-} ]]; then
        cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp -I "$kernel/include" \
            "$UKE_NATIVE_VIDEO_SOURCE" > "$output/video.dts"
        sed '/^\/dts-v1\/;/d; /^\/plugin\/;/d' "$output/video.dts" >> "$output/display-$variant.dts"
    fi
    dtc -q -@ -I dts -O dtb -o "$output/display-$variant.dtbo" "$output/display-$variant.dts"
    {
        printf 'static unsigned char uke_native_overlay_%s[] __initdata __aligned(8) = {\n' "$variant"
        od -An -v -tx1 "$output/display-$variant.dtbo" | sed -E 's/[a-f0-9]{2}/0x&,/g'
        printf '};\n'
    } >> "$header"
done
{
    printf 'static const struct uke_native_panel uke_native_panels[] __initconst = {\n'
    for variant in "${variants[@]}"; do
        if [[ $variant == 36 ]]; then suffix=36_02_0a; else suffix=42_02_0b; fi
        printf '\t{ "msm_drm.dsi_display0=qcom,mdss_dsi_o82_%s_dualdsi_dsc_vid", uke_native_overlay_%s, sizeof(uke_native_overlay_%s) },\n' "$suffix" "$variant" "$variant"
    done
    printf '};\n'
} >> "$header"
# Retain the historical fixture filenames; boot uses the complete table above.
cp "$output/display-${variants[-1]}.dts" "$output/display.dts"
cp "$output/display-${variants[-1]}.dtbo" "$output/display.dtbo"
install -m644 "$header" "$kernel/arch/arm64/kernel/uke-native-display.h"
