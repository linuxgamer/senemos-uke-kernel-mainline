#!/usr/bin/env bash
# COPR only: actual prepared12000 KMS objects and synthetic memory/PA fixtures.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
[[ $(uname -m) == aarch64 ]]
kernel=$(realpath "${1:?Pass the prepared qualified kernel}")
out=$(realpath -m "${2:?Pass the remote object directory}")
addon=$(cd -- "$(dirname -- "$0")/../.." && pwd)
manifest=manifests/o82-memory-path-source-20261105.json
(cd "$addon"; jq -r '.archive_assets[]|.sha256+"  "+.path' "$manifest" | sha256sum -c --strict --quiet -)
profile=$kernel/native-profile
[[ $(cat "$profile/source-commit") == ad6b68ff403d57bc8e64b4f92e0dcfa41ea43e09 ]]
printf '%s  %s\n' 739882b3a07fc6a701bae81ac6623a4b576871bd4289de3a095acabc20d49d34 \
    "$profile/native.config" | sha256sum -c --strict -
printf '%s  %s\n' 068c2f0bcdfa6598fd8cf4b95a6f13ef8db090c83d8099fb793ec21ab6597501 \
    "$profile/source-composition.json" | sha256sum -c --strict -
target=$kernel/drivers/gpu/drm/msm/disp/dpu1
while IFS=$'\t' read -r relative before; do
    [[ $relative =~ ^src/display/[a-zA-Z0-9_.-]+$ ]]
    if [[ $before == absent ]]; then
        test ! -e "$target/${relative##*/}"
    else
        printf '%s  %s\n' "$before" "$profile/$relative" | sha256sum -c --strict --quiet -
        cmp "$profile/$relative" "$target/${relative##*/}"
    fi
    install -m644 "$addon/$relative" "$target/${relative##*/}"
done < <(jq -r '.kernel_imports[]|[.path,(.before_sha256 // "absent")]|@tsv' "$addon/$manifest")
mkdir -p "$out"
for compiler in g++ clang++; do
    flags=(-std=c++20 -O2 -UNDEBUG -Wall -Wextra -Werror -I"$addon/src/display")
    [[ $compiler != clang++ ]] || flags+=(-O1 -g -fsanitize=address,undefined
        -fno-sanitize-recover=all -fno-omit-frame-pointer)
    "$compiler" "${flags[@]}" "$addon/tests/o82-memory-pipeline-contract.cpp" -o "$out/memory-helper-check"
    "$out/memory-helper-check"
done
bash "$addon/tests/o82-lutbus-contract.sh"
bash "$addon/tests/o82-profile-loader-contract.sh" "$addon"
bash "$addon/tests/o82-regdma-transport-contract.sh" "$addon" "$kernel"
bash "$addon/tests/o82-atomic-contract.sh" "$addon" "$kernel"
mkdir -p "$out"
cp "$profile/native.config" "$out/.config"
export ARCH=arm64 LLVM=1 LLVM_IAS=1
bash "$kernel/scripts/config" --file "$out/.config" --set-str INITRAMFS_SOURCE ''
make -s -C "$kernel" O="$out" olddefconfig
grep -Fx CONFIG_DRM_MSM=m "$out/.config"
printf '%s  %s\n' 81763fc03ea0ebf254ab7427af2113dc0c7c0d80dceab61232b6e371463d1f90 \
    "$kernel/drivers/gpu/drm/msm/registers/gen_header.py" | sha256sum -c --strict -
# The existing upstream XML/header generator is host-only in this COPR worker.
make -s -C "$kernel" O="$out" KCFLAGS=-Werror -j4 drivers/gpu/drm/msm/msm.o
linked=$out/drivers/gpu/drm/msm/msm.o
test -s "$linked"
readelf -h "$linked" | grep -E 'Machine:.*AArch64'
for function in dpu_o82_lutbus_build dpu_o82_power_upload dpu_o82_profiles_input \
    dpu_o82_color_commit dpu_o82_upload; do
    llvm-nm --defined-only "$linked" | awk -v name="$function" \
        '$2 ~ /^[tT]$/ && $3==name {found=1} END {exit !found}'
done
llvm-nm --undefined-only "$linked" > "$out/memory-undefined.txt"
if grep -E ' dpu_o82_(platform|regdma|upload|lutbus|power|color|profiles)_' "$out/memory-undefined.txt"; then exit 1; fi
node=/fragment@208/__overlay__/display-subsystem@ae00000/display-controller@ae01000
for supplier in 36 42; do
    overlay=$kernel/native-generated/display-$supplier.dtbo
    [[ $(fdtget -t s "$overlay" "$node" compatible) == qcom,sm7675-dpu ]]
    [[ $(fdtget -t x "$overlay" "$node" reg) == 'ae01000 8f000 aeb0000 1074 af80000 7000' ]]
done
printf '%s  %s\n' 739882b3a07fc6a701bae81ac6623a4b576871bd4289de3a095acabc20d49d34 \
    "$profile/native.config" | sha256sum -c --strict -
printf '%s\n' 'Actual qualified12000 MSM object links with the memory/protection path; both supplier DT resources and raw profile configuration retained'
printf '%s\n' 'No Image/module/boot delivery, JSON mapping, private bundle activation or physical HDR acceptance is established'
