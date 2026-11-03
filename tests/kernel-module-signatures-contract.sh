#!/usr/bin/env bash
# COPR-only: verify every final module against this build's exported certificate.
set -Eeuo pipefail
kernel=$(realpath "${1:?Pass the prepared kernel source}")
modules=$(realpath "${2:?Pass the staged versioned module directory}")
certificate=$(realpath "${3:?Pass the build certificate in DER form}")
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
extract=$kernel/scripts/extract-module-sig.pl
openssl x509 -inform DER -in "$certificate" -out "$work/certificate.pem"
openssl x509 -in "$work/certificate.pem" -noout -text > "$work/certificate.txt"
grep -Fq 'Public-Key: (4096 bit)' "$work/certificate.txt"
verify_signature() {
    openssl cms -verify -binary -inform DER -in "$work/signature.der" \
        -content "$1" -certfile "$2" -nointern -noverify -out /dev/null \
        > "$work/verify.log" 2>&1
}
count=0
while IFS= read -r -d '' module; do
    case $module in
        *.ko.zst) zstd -q -d -c -- "$module" > "$work/module.ko";;
        *.ko) cp -- "$module" "$work/module.ko";;
        *) echo 'Unsupported module compression' >&2; exit 1;;
    esac
    test "$(modinfo -F sig_hashalgo "$work/module.ko")" = sha256
    perl "$extract" -0 "$work/module.ko" > "$work/payload" 2> "$work/extract.log"
    perl "$extract" -s "$work/module.ko" > "$work/signature.der" 2>> "$work/extract.log"
    verify_signature "$work/payload" "$work/certificate.pem" || {
        printf 'Module signature rejected: %s\n' "$module" >&2
        cat "$work/verify.log" >&2; exit 1;
    }
    count=$((count + 1))
done < <(find "$modules/kernel" -type f -name '*.ko*' -print0)
test "$count" -gt 0
# Retain the last real signature for rejection controls; no modules are loaded.
cp "$work/payload" "$work/tampered"
printf '\000' | dd of="$work/tampered" bs=1 count=1 conv=notrunc status=none
if verify_signature "$work/tampered" "$work/certificate.pem"; then
    echo 'Tampered module unexpectedly verified' >&2; exit 1
fi
if perl "$extract" -s "$work/payload" > /dev/null 2>&1; then
    echo 'Unsigned module unexpectedly accepted' >&2; exit 1
fi
openssl req -new -newkey rsa:2048 -nodes -x509 -sha256 -days 1 \
    -subj '/CN=Uke negative signature control' -keyout "$work/wrong.key" \
    -out "$work/wrong.pem" > "$work/keygen.log" 2>&1
if verify_signature "$work/payload" "$work/wrong.pem"; then
    echo 'Wrong certificate unexpectedly verified' >&2; exit 1
fi
printf 'Verified %s module signatures; tampered, unsigned and wrong-key controls refused\n' "$count"
