#!/usr/bin/env bash
# Use the kernel's actual Kconfig frontend and driver stanzas, host only.
set -Eeuo pipefail
kernel=${1:?Pass prepared kernel source}
conf=$(realpath "${2:?Pass built host scripts/kconfig/conf}")
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
{
    printf 'mainmenu "USBSS dependency fixture"\nconfig MODULES\n\tbool "Modules"\n\tmodules\n'
    for symbol in I2C REGMAP_I2C OF REGULATOR GPIOLIB PINCTRL RESET_CONTROLLER; do
        printf 'config %s\n\ttristate "%s"\n' "$symbol" "$symbol"
    done
    for pair in 'drivers/usb/typec/mux/Kconfig TYPEC_MUX_UKE_WCD939X' 'drivers/usb/common/Kconfig USB_WCD939X_UKE'; do
        read -r file symbol <<< "$pair"
        awk -v symbol="$symbol" '$0=="config "symbol {emit=1} emit && /^config / && $0!="config "symbol {exit} emit && /^(endmenu|endif)/ {exit} emit {print}' "$kernel/$file"
    done
} > "$work/Kconfig"
for missing in none OF REGULATOR GPIOLIB PINCTRL RESET_CONTROLLER I2C; do
    {
        printf 'CONFIG_MODULES=y\nCONFIG_TYPEC_MUX_UKE_WCD939X=m\nCONFIG_USB_WCD939X_UKE=y\n'
        for symbol in I2C OF REGULATOR GPIOLIB PINCTRL RESET_CONTROLLER; do
            if [[ $symbol == "$missing" ]]; then printf '# CONFIG_%s is not set\n' "$symbol"; else printf 'CONFIG_%s=y\n' "$symbol"; fi
        done
    } > "$work/.config"
    (cd "$work"; KCONFIG_CONFIG="$work/.config" "$conf" --olddefconfig "$work/Kconfig") > "$work/frontend.log" 2>&1
    if [[ $missing == none ]]; then
        grep -Fxq 'CONFIG_TYPEC_MUX_UKE_WCD939X=m' "$work/.config"
    else
        ! grep -Eq '^CONFIG_TYPEC_MUX_UKE_WCD939X=[ym]$' "$work/.config" || { printf 'USBSS selected without %s\n' "$missing" >&2; exit 1; }
    fi
    case $missing in
        none|OF|PINCTRL|RESET_CONTROLLER) grep -Fxq 'CONFIG_USB_WCD939X_UKE=y' "$work/.config" || { printf 'Legacy USB2 incorrectly requires %s\n' "$missing" >&2; exit 1; };;
        *) ! grep -Eq '^CONFIG_USB_WCD939X_UKE=[ym]$' "$work/.config";;
    esac
done
printf 'Actual Kconfig: USBSS requires every reset/pin/supply dependency; legacy USB2 remains available without new framework dependencies; host only\n'
