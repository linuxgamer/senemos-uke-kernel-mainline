#!/usr/bin/env bash
# COPR only: retain the complete actual callbacks and front-light assertions.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
owner=$(cd -- "$(dirname -- "$0")/.." && pwd)
profile=$(realpath "${1:?Complete native profile}")
kernel=$(realpath "${2:?Prepared cumulative kernel}")
order=${3:-metadata-first}
[[ $order == metadata-first || $order == vectors-first ]]
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
mkdir -p "$stage/src/sensors" "$stage/tests"
for path in src/sensors/uke-ssc-iio.c src/sensors/uke-ssc-protocol.c src/sensors/uke-ssc-protocol.h \
    tests/ssc-native-host.h tests/ssc-native-contract.sh; do
    install -m644 "$profile/$path" "$stage/$path"
done
[[ $(grep -c '^int main(void)$' "$profile/tests/ssc-native-contract.c") == 1 ]]
awk -v front="$owner/tests/ssc-als-vector-contract.c" -v rear="$owner/tests/ssc-rear-als-contract.c" -v order="$order" '
 /^int main\(void\)$/ {
   while ((getline line < front)>0) print line; close(front);
   while ((getline line < rear)>0) print line; close(rear); inject=1
 }
 {print}
 inject && /^\{$/ {
   print "\tals_vectors();als_vector_reports();";
   if(order=="vectors-first") print "\trear_vectors();rear_metadata_contract();";
   else print "\trear_metadata_contract();rear_vectors();";
   print "\trear_reports();"; inject=0; calls++
 }
 END {if(calls!=1)exit 1}
' "$profile/tests/ssc-native-contract.c" > "$stage/tests/ssc-native-contract.c"
bash "$stage/tests/ssc-native-contract.sh" "$kernel"
