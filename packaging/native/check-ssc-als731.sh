#!/usr/bin/env bash
# COPR only: source/actual callbacks and the real AArch64 SSC composite object.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
[[ $(uname -m) == aarch64 ]]
kernel=$(realpath "${1:?Prepared cumulative kernel}")
output=$(realpath -m "${2:?Object output}")
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
profile=$kernel/native-profile
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
manifest=$owner/manifests/ssc-stk3bcx-als-layer-20261105.json
path=src/sensors/uke-ssc-iio.c
jq -e '.ssc_stk3bcx_als_layer==1 and .ssc_stk3bcx_als_shapes==[2,6] and
 (.ssc_stk3bcx_als_physical_acceptance|not) and .ssc_early_sample_layer==2' \
 "$profile/source-composition.json" >/dev/null
cmp "$profile/$path" "$kernel/drivers/iio/common/uke-ssc/uke-ssc-iio.c"
mkdir -p "$stage/original/src/sensors" "$stage/original/tests"
for input in src/sensors/uke-ssc-iio.c src/sensors/uke-ssc-protocol.c src/sensors/uke-ssc-protocol.h \
    tests/ssc-native-host.h tests/ssc-native-contract.c tests/ssc-native-contract.sh; do
    install -m644 "$profile/$input" "$stage/original/$input"
done
(cd "$stage/original"; patch -Rp1 --fuzz=0 --batch -i "$owner/src/sensors/0001-ssc-stk3bcx-als-vector.patch")
printf '%s  %s\n' "$(jq -er .before_sha256 "$manifest")" "$stage/original/$path" | sha256sum -c --strict -
for compiler in gcc clang; do
    cp "$stage/original/tests/ssc-native-contract.sh" "$stage/original/tests/native.bak"
    sed "s/for compiler in gcc clang; do/for compiler in $compiler; do/" \
      "$stage/original/tests/native.bak" > "$stage/original/tests/ssc-native-contract.sh"
    if (ulimit -c 0; bash "$owner/tests/ssc-als-vector-contract.sh" "$stage/original" "$kernel") \
        > "$stage/negative-$compiler.log" 2>&1; then
        printf 'ALS fixture missed the exact original vector refusal\n' >&2; exit 1
    fi
    grep -q 'als_vectors.*Assertion.*ret == 0' "$stage/negative-$compiler.log"
    install -m644 "$stage/original/tests/native.bak" "$stage/original/tests/ssc-native-contract.sh"
    printf 'Exact production six-field ALS refusal reproduced: %s\n' "$compiler"
done
bash "$owner/tests/ssc-als-vector-contract.sh" "$profile" "$kernel"
bash "$profile/packaging/native/check-cumulative-camera731.sh" "$kernel" "$output" prepared
mkdir -p "$output" "$stage/reference"
for dir in "$output" "$stage/reference"; do
    cp "$profile/native.config" "$dir/.config"
    bash "$kernel/scripts/config" --file "$dir/.config" --set-str INITRAMFS_SOURCE "$output/boot-initramfs.cpio.gz"
    make -s -C "$kernel" O="$dir" ARCH=arm64 LLVM=1 LLVM_IAS=1 olddefconfig
done
cmp "$output/.config" "$stage/reference/.config"
make -s -C "$kernel" O="$output" ARCH=arm64 LLVM=1 LLVM_IAS=1 LOCALVERSION=-12204-unstable -j4 prepare modules_prepare
make -s -C "$kernel" O="$output" ARCH=arm64 LLVM=1 LLVM_IAS=1 LOCALVERSION=-12204-unstable KCFLAGS=-Werror -j4 \
    drivers/iio/common/uke-ssc/uke-ssc.o
llvm-readelf -h "$output/drivers/iio/common/uke-ssc/uke-ssc.o" | grep -E 'Machine:.*AArch64|Type:.*REL'
sha256sum "$output/drivers/iio/common/uke-ssc/uke-ssc.o" "$profile/$path" "$output/.config"
test ! -e "$output/arch/arm64/boot/Image"
test -z "$(find "$output" -type f -name '*.ko' -print -quit)"
printf '%s\n' 'PASS: exact former six-value ALS refusal; named front-only2/6 vectors and retained actual callbacks; real cumulative AArch64 SSC object-Werror' \
 'Scope: source/config/object only; no final Image/module or target/optical/lifecycle acceptance'
