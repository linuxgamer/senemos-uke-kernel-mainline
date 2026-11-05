#!/usr/bin/env bash
# COPR only: add synthetic OEM-vector assertions to the retained real callbacks.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
owner=$(cd -- "$(dirname -- "$0")/.." && pwd)
profile=$(realpath "${1:?Complete native profile}")
kernel=$(realpath "${2:?Prepared cumulative kernel}")
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
mkdir -p "$stage/src/sensors" "$stage/tests"
for path in src/sensors/uke-ssc-iio.c src/sensors/uke-ssc-protocol.c src/sensors/uke-ssc-protocol.h \
    tests/ssc-native-host.h tests/ssc-native-contract.sh; do
    install -m644 "$profile/$path" "$stage/$path"
done
[[ $(grep -c '^int main(void)$' "$profile/tests/ssc-native-contract.c") == 1 ]]
awk -v extra="$owner/tests/ssc-als-vector-contract.c" '
 /^int main\(void\)$/ {while ((getline line < extra)>0) print line; close(extra); inject=1}
 {print}
 inject && /^\{$/ {print "\tals_vectors();als_vector_reports();"; inject=0; calls++}
 END {if(calls!=1)exit 1}
' "$profile/tests/ssc-native-contract.c" > "$stage/tests/ssc-native-contract.c"
bash "$stage/tests/ssc-native-contract.sh" "$kernel"
