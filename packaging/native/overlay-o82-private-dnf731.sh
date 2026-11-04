#!/usr/bin/env bash
# COPR/source only: three packaging lines, no kernel/config/DT/boot-source edit.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
spec=$(realpath "${1:?Pass the complete unstable kernel spec}")
profile=$(realpath "${2:?Pass the qualified memory/v5 source profile}")
(cd "$profile"; sha256sum -c --strict --quiet SHA256SUMS)
grep -Fxq 'Name: senemos-uke-linux-kernel-mainline-unstable' "$spec"
jq -e '.package_family=="senemos-uke-linux-kernel-mainline-unstable" and
 .o82_memory_layer==1 and .o82_private_color_bundle_version==5 and
 .o82_memory_software_support and .o82_memory_protection_software_support and
 .o82_explicit_neutral_memory and .o82_color_initial_preset=="" and
 .o82_color_dma_enabled==false and .native_hdr_advertised==false' \
 "$profile/source-composition.json" >/dev/null
cap='Requires: uke-kernel-update(o82-private-color-v5) >= 1'
utility='Requires: uke-o82-color-profile >= 0.7.0-1'
marker='printf '\''o82_private_color=5\n'\'' >> "$bundle/manifest"'
verify()
{
    [[ $(grep -Fxc "$cap" "$1") == 1 && $(grep -Fxc "$utility" "$1") == 1 &&
       $(grep -Fxc "$marker" "$1") == 1 ]]
    awk -v cap="$cap" -v utility="$utility" '
      /^%package boot$/ {section=1;next}
      /^%description boot$/ {section=0}
      $0==cap {if(!section)exit 1;caps++}
      $0==utility {if(!section)exit 1;utilities++}
      END {if(caps!=1||utilities!=1)exit 1}' "$1"
    O82_DNF_MARKER="$marker" awk 'BEGIN {marker=ENVIRON["O82_DNF_MARKER"]}
      $0==marker {if(previous!="install -m644 %{_uke_out}/boot-manifest \"$bundle/manifest\"")exit 1;found++}
      {previous=$0} END {if(found!=1)exit 1}' "$1"
}
if grep -Eq 'o82-private-color-v5|o82_private_color=|Requires: uke-o82-color-profile' "$spec"; then
    verify "$spec"
    printf 'Private-color DNF packaging already exact; no mutation\n'
    exit 0
fi
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
O82_DNF_MARKER="$marker" awk -v cap="$cap" -v utility="$utility" 'BEGIN {marker=ENVIRON["O82_DNF_MARKER"]}
 /^%package boot$/ {print;print cap;print utility;packages++;next}
 {print}
 $0=="install -m644 %{_uke_out}/boot-manifest \"$bundle/manifest\"" {print marker;manifests++}
 END {if(packages!=1||manifests!=1)exit 1}' "$spec" > "$work/next.spec"
verify "$work/next.spec"
O82_DNF_MARKER="$marker" awk -v cap="$cap" -v utility="$utility" \
 'BEGIN {marker=ENVIRON["O82_DNF_MARKER"]} $0!=cap&&$0!=utility&&$0!=marker' "$work/next.spec" > "$work/restored.spec"
cmp "$spec" "$work/restored.spec"
install -m644 "$work/next.spec" "$spec"
printf 'Private-color DNF packaging: exactly two boot dependencies and one RPM-owned manifest marker\n'
