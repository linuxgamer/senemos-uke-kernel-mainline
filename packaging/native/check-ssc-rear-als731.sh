#!/usr/bin/env bash
# COPR only: named logical rear ALS with all front/cumulative source controls.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
[[ $(uname -m) == aarch64 ]]
kernel=$(realpath "${1:?Prepared cumulative kernel}")
output=$(realpath -m "${2:?Object output}")
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
profile=$kernel/native-profile
manifest=$owner/manifests/ssc-sip1328-als-layer-20261105.json
path=src/sensors/uke-ssc-iio.c
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
jq -e '.ssc_sip1328_als_layer==1 and .ssc_sip1328_als_shapes==[2,6] and
 (.ssc_sip1328_als_physical_acceptance|not) and .ssc_stk3bcx_als_layer==1 and
 .ssc_early_sample_layer==2' "$profile/source-composition.json" >/dev/null
printf '%s  %s\n' "$(jq -er .after_sha256 "$manifest")" "$profile/$path" | sha256sum -c --strict -
cmp "$profile/$path" "$kernel/drivers/iio/common/uke-ssc/uke-ssc-iio.c"
for control in original front; do
    base=$stage/$control
    mkdir -p "$base/src/sensors" "$base/tests"
    for input in src/sensors/uke-ssc-iio.c src/sensors/uke-ssc-protocol.c src/sensors/uke-ssc-protocol.h \
        tests/ssc-native-host.h tests/ssc-native-contract.c tests/ssc-native-contract.sh; do
        install -m644 "$profile/$input" "$base/$input"
    done
    (cd "$base"; patch -Rp1 --fuzz=0 --batch -i "$owner/src/sensors/0002-ssc-sip1328-rear-als.patch")
    digest=$(jq -er .before_sha256 "$manifest")
    expected='rear_metadata_contract.*Assertion.*usable == expected'
    if [[ $control == original ]]; then
        (cd "$base"; patch -Rp1 --fuzz=0 --batch -i "$owner/src/sensors/0001-ssc-stk3bcx-als-vector.patch")
        digest=$(jq -er .original_sha256 "$manifest")
        expected='als_vectors.*Assertion.*ret == 0'
    fi
    printf '%s  %s\n' "$digest" "$base/$path" | sha256sum -c --strict -
    orders=(metadata-first)
    [[ $control != front ]] || orders+=(vectors-first)
    for order in "${orders[@]}"; do
      expected='als_vectors.*Assertion.*ret == 0'
      if [[ $control == front ]]; then
        expected='rear_metadata_contract.*Assertion.*usable == expected'
        [[ $order != vectors-first ]] || expected='rear_vectors.*Assertion.*ssc_sample_values'
      fi
      for compiler in gcc clang; do
        cp "$base/tests/ssc-native-contract.sh" "$stage/native.before"
        sed "s/for compiler in gcc clang; do/for compiler in $compiler; do/" \
            "$stage/native.before" > "$base/tests/ssc-native-contract.sh"
        if (ulimit -c 0; bash "$owner/tests/ssc-rear-als-contract.sh" "$base" "$kernel" "$order") \
            > "$stage/$control-$compiler.log" 2>&1; then
            printf 'Rear ALS fixture missed %s/%s refusal\n' "$control" "$compiler" >&2; exit 1
        fi
        grep -q "$expected" "$stage/$control-$compiler.log"
        install -m644 "$stage/native.before" "$base/tests/ssc-native-contract.sh"
        printf 'Exact %s/%s ALS refusal reproduced: %s\n' "$control" "$order" "$compiler"
      done
    done
done
bash "$owner/tests/ssc-rear-als-contract.sh" "$profile" "$kernel"
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
printf '%s\n' 'PASS: exact original/front-only refusals; named logical rear ALS and retained front callbacks; cumulative AArch64 SSC object-Werror' \
 'Scope: source/config/object only; no final Image/module, target install or physical light/lifecycle acceptance'
