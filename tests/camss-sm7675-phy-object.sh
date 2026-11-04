#!/usr/bin/env bash
# COPR only. Use the prepared actual kernel tree; never link or install this object.
set -Eeuo pipefail
[[ $# == 3 ]] || exit 2
kernel=$(realpath "$1")
output=$(realpath "$2")
release=$3
[[ $release =~ ^7\.3\.1-[1-9][0-9]{3,4}$ ]]
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test -f "$output/include/generated/autoconf.h"
test ! -e "$output/arch/arm64/boot/Image"
stage=$output/camss-sm7675-phy-object
mkdir -p "$stage"
cp "$kernel/drivers/media/platform/qcom/camss/camss-csiphy-3ph-1-0.c" "$stage/camss-sm7675-phy.c"
cat >> "$stage/camss-sm7675-phy.c" <<'WRAPPER'
#include "csiphy-sm7675.h"
int uke_camss_sm7675_phy_object_check(void __iomem *base,
	const struct csiphy_sm7675_config *config, bool stop);
int uke_camss_sm7675_phy_object_check(void __iomem *base,
	const struct csiphy_sm7675_config *config, bool stop)
{
	if (stop) {
		csiphy_sm7675_stop(base);
		return 0;
	}
	return csiphy_sm7675_program(base, config);
}
WRAPPER
printf '%s\n' 'obj-y += camss-sm7675-phy.o' \
 "ccflags-y += -I$project/src/camera/camss -I$kernel/drivers/media/platform/qcom/camss" > "$stage/Makefile"
make -C "$kernel" ARCH=arm64 LLVM=1 LLVM_IAS=1 O="$output" M="$stage" \
 LOCALVERSION="-${release#7.3.1-}" KCFLAGS=-Werror camss-sm7675-phy.o
llvm-readelf -h "$stage/camss-sm7675-phy.o" | grep -E 'Machine:.*AArch64'
test -z "$(llvm-readelf -SW "$stage/camss-sm7675-phy.o" | grep -F '.initcall' || true)"
test ! -e "$output/arch/arm64/boot/Image"
printf 'Uke CSIPHY helper compiled with complete actual native source; no initcall, link or installation\n'
