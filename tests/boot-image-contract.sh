#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 1 && -x $1 ]]
codec=$(realpath "$1")
fixture=$(mktemp -d); trap 'rm -rf "$fixture"' EXIT
cd "$fixture"
truncate -s 65536 stock
printf 'ANDROID!\100\000\000\000' | dd of=stock conv=notrunc status=none
printf '\060\006\000\000' | dd of=stock bs=1 seek=20 conv=notrunc status=none
printf '\004\000\000\000' | dd of=stock bs=1 seek=40 conv=notrunc status=none
truncate -s 64 Image
printf '\100\000\000\000\000\000\000\000' | dd of=Image bs=1 seek=16 conv=notrunc status=none
printf '\101\122\115\144' | dd of=Image bs=1 seek=56 conv=notrunc status=none
"$codec" pack stock Image boot 65536
"$codec" inspect boot | jq -e '.kernel_bytes==64 and .ramdisk_bytes==0 and .signature_bytes==0 and .avb_footer_present==false' >/dev/null
"$codec" extract boot unpacked
cmp Image unpacked
"$codec" create Image canonical
"$codec" inspect canonical | jq -e '.image_bytes==100663296 and .os_version_encoded==570425768 and .kernel_bytes==64 and .ramdisk_bytes==0 and .signature_bytes==0 and .avb_footer_present==false' >/dev/null
"$codec" extract canonical canonical-Image
cmp Image canonical-Image
"$codec" create Image userdata userdata
"$codec" extract userdata userdata-Image
cmp canonical-Image userdata-Image
[[ $(dd if=userdata bs=1 skip=44 count=21 status=none | tr -d '\000') == senemos.root=userdata ]]
# Both containers differ only in the bounded header selector, not the Image.
cmp <(dd if=canonical bs=4096 skip=1 status=none) <(dd if=userdata bs=4096 skip=1 status=none)
reject() { if "$codec" "$@" >/dev/null 2>&1; then echo 'Malformed image accepted' >&2; exit 1; fi; }
reject create Image bad-profile system
reject create Image injected-profile 'userdata root=/dev/unsafe'
reject create Image empty-profile ''
reject pack stock Image boot 65536
reject pack stock Image undersized 4096
reject pack stock Image mismatch 131072
reject pack stock Image invalid -1
ln -s boot link
reject pack stock Image link 65536
reject inspect link
reject inspect /dev/null
mkfifo fifo
reject inspect fifo
cp stock corrupt
printf X | dd of=corrupt conv=notrunc status=none
reject inspect corrupt
cp stock truncated
printf '\377\377\377\177' | dd of=truncated bs=1 seek=8 conv=notrunc status=none
reject inspect truncated
cp stock signature
printf '\001\000\000\000' | dd of=signature bs=1 seek=1580 conv=notrunc status=none
reject pack signature Image signed 65536
cp stock ramdisk
printf '\001\000\000\000' | dd of=ramdisk bs=1 seek=12 conv=notrunc status=none
reject pack ramdisk Image external 65536
cp stock reserved
printf '\001' | dd of=reserved bs=1 seek=24 conv=notrunc status=none
reject inspect reserved
cp stock cmdline
dd if=/dev/zero bs=1536 count=1 status=none | tr '\000' A | dd of=cmdline bs=1 seek=44 conv=notrunc status=none
reject inspect cmdline
cp Image foreign
printf '\000\000\000\000' | dd of=foreign bs=1 seek=56 conv=notrunc status=none
reject pack stock foreign nonarm 65536
cp Image bigendian
printf '\001' | dd of=bigendian bs=1 seek=24 conv=notrunc status=none
reject pack stock bigendian wrongendian 65536
cp Image oversized
truncate -s 131072 oversized
reject pack stock oversized overflow 65536
cp stock footer
printf AVBf | dd of=footer bs=1 seek=65472 conv=notrunc status=none
"$codec" pack footer Image without-footer 65536
"$codec" inspect without-footer | jq -e '.avb_footer_present==false' >/dev/null
echo 'Native boot v4 roundtrip, size, signature, malformed input and symlink/device rejection passed'
