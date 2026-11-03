#!/usr/bin/env bash
# Host-only overlay application; the input FDT stays private and unchanged.
set -Eeuo pipefail
kernel=${1:?Pass the candidate kernel source with its SM7675 clock header}
baseline=${2:?Pass the private live Uke handoff DTB}
here=$(cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp -I "$kernel/include" \
    "$here/../src/video/sm7675-uke-native-video.dtso" > "$work/video.dts"
dtc -q -@ -I dts -O dtb -o "$work/video.dtbo" "$work/video.dts"
fdtoverlay -i "$baseline" -o "$work/merged.dtb" "$work/video.dtbo"
iris=/soc/video-codec@aa00000
test "$(fdtget -t s "$work/merged.dtb" "$iris" status)" = okay
test "$(fdtget -t s "$work/merged.dtb" /soc/qcom,vidc@aa00000 status)" = disabled
test "$(fdtget -t s "$work/merged.dtb" /soc/clock-controller@aaf0000 status)" = okay
for suffix in 804c 80a4 8078 80cc; do
    node=/soc/qcom,gdsc@aaf$suffix
    test "$(fdtget -t s "$work/merged.dtb" "$node" status)" = disabled
    test "$(fdtget -t x "$work/merged.dtb" "$node" reg)" = \
         "$(fdtget -t x "$baseline" "$node" reg)"
done
test "$(fdtget -t s "$work/merged.dtb" "$iris" reset-names)" = 'bus xo core vcodec'
videocc=$(fdtget -t x "$baseline" /soc/clock-controller@aaf0000 phandle)
test "$(fdtget -t x "$work/merged.dtb" "$iris" power-domains)" = "$videocc 0 $videocc 1"
# CVP remains the baseline unbound node; its shared reset needs separate acceptance.
test "$(fdtget -t x "$work/merged.dtb" /soc/qcom,cvp@ab00000 resets)" = \
     "$(fdtget -t x "$baseline" /soc/qcom,cvp@ab00000 resets)"
test "$(fdtget -t x "$work/merged.dtb" "$iris" reg)" = 'aa00000 f0000'
test "$(fdtget -t x "$work/merged.dtb" "$iris" interrupts)" = '0 ae 4'
memory=/reserved-memory/video_region@9899c000
test "$(fdtget -t x "$baseline" "$memory" reg)" = \
     "$(fdtget -t x "$work/merged.dtb" "$memory" reg)"
test "$(fdtget -t x "$work/merged.dtb" "$iris" memory-region)" = \
     "$(fdtget -t x "$baseline" "$memory" phandle)"
smmu=$(fdtget -t x "$baseline" /soc/apps-smmu@15000000 phandle)
test "$(fdtget -t x "$work/merged.dtb" "$iris" iommus)" = "$smmu 1940 0 $smmu 1947 0"
printf 'Live-FDT offline graph: native domains/resets resolved, OEM GDSCs disabled, reservation/CVP retained\n'
