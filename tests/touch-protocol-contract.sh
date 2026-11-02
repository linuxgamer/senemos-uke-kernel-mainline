#!/usr/bin/env bash
# Compile the actual kernel C consumer against small host header shims.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
sanitize=()
[[ -z ${UKE_TOUCH_SANITIZE:-} ]] || sanitize=("-fsanitize=address,undefined" -fno-omit-frame-pointer)
mkdir -p "$stage/linux"
cat > "$stage/linux/types.h" <<'C'
#ifndef UKE_TOUCH_TYPES
#define UKE_TOUCH_TYPES
#include_next <linux/types.h>
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
typedef uint8_t u8;
typedef uint16_t u16;
typedef int16_t s16;
typedef int32_t s32;
typedef uint32_t u32;
typedef uint64_t u64;
#endif
C
cat > "$stage/linux/unaligned.h" <<'C'
#include <linux/types.h>
static inline u16 get_unaligned_le16(const void *p) {
 const u8 *b=p; return (u16)((u16)b[0] | ((u16)b[1]<<8));
}
static inline u32 get_unaligned_le32(const void *p) {
 const u8 *b=p; return get_unaligned_le16(b) | ((u32)get_unaligned_le16(b+2)<<16);
}
static inline void put_unaligned_le16(u16 v,void *p) {
 u8 *b=p; b[0]=(u8)v; b[1]=(u8)(v>>8);
}
static inline void put_unaligned_le32(u32 v,void *p) {
 u8 *b=p; put_unaligned_le16((u16)v,b);put_unaligned_le16((u16)(v>>16),b+2);
}
C
printf '#include <string.h>\n' > "$stage/linux/string.h"
# glibc's errno header imports Linux errno; retain the system constants there.
printf '#include_next <linux/errno.h>\n' > "$stage/linux/errno.h"
"${CC:-cc}" -std=gnu11 -O2 -g -Wall -Wextra -Werror -Wconversion \
    -I "$stage" "$root/tests/touch-protocol.c" "$root/src/input/nt36532-uke-protocol.c" \
    "${sanitize[@]}" -o "$stage/check"
"$stage/check"
"${CC:-cc}" -std=gnu11 -O2 -g -Wall -Wextra -Werror -Wconversion \
    -DNVT_TEST_VARIANT=NVT_UKE_TIANMA -I "$stage" "$root/tests/touch-protocol.c" \
    "$root/src/input/nt36532-uke-protocol.c" "${sanitize[@]}" -o "$stage/check-tianma"
"$stage/check-tianma"
"${CC:-cc}" -std=gnu11 -O2 -g -Wall -Wextra -Werror -Wconversion \
    -I "$stage" "$root/tests/touch-gesture.c" "$root/src/input/nt36532-uke-protocol.c" \
    "${sanitize[@]}" -o "$stage/gesture"
"$stage/gesture"
"${CC:-cc}" -std=gnu11 -O2 -g -Wall -Wextra -Werror -Wconversion \
    -I "$stage" "$root/tests/touch-matrix.c" "$root/src/input/nt36532-uke-matrix.c" \
    "$root/src/input/nt36532-uke-protocol.c" "${sanitize[@]}" -o "$stage/matrix"
"$stage/matrix" "$@"
awk '
 /^static void nvt_release_contacts\(/ || /^static int nvt_stable_axis\(/ || /^static void nvt_order_new_slots\(/ || /^static void nvt_publish_contacts\(/ { copying=1 }
 copying { print }
 copying && /^}/ { copying=0 }
' "$root/src/input/nt36532-uke-spi.c" > "$stage/production-contacts.h"
[[ $(grep -c '^static void ' "$stage/production-contacts.h") == 3 ]]
[[ $(grep -c '^static int nvt_stable_axis' "$stage/production-contacts.h") == 1 ]]
"${CC:-cc}" -std=gnu11 -O2 -g -Wall -Wextra -Werror -Wconversion \
    -I "$stage" "$root/tests/touch-publish.c" \
    "${sanitize[@]}" -o "$stage/publish"
"$stage/publish"
printf 'Production input publisher: slots, lifts, packet failure and quiesce releases: PASS\n'
printf 'Checked Uke gesture command sequence, checksum, filtering and failure paths: PASS\n'
if [[ -n ${UKE_TOUCH_REFERENCE_DECODER:-} ]]; then
    [[ -f $UKE_TOUCH_REFERENCE_DECODER ]]
    "${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -I "$stage" \
        "${sanitize[@]}" -c "$root/src/input/nt36532-uke-protocol.c" -o "$stage/protocol.o"
    "${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -I "$stage" \
        "-DUKE_TOUCH_REFERENCE_DECODER=\"$UKE_TOUCH_REFERENCE_DECODER\"" \
        "${sanitize[@]}" "$root/tests/touch-protocol-equivalence.cpp" "$stage/protocol.o" -o "$stage/equivalence"
    "$stage/equivalence" "$@"
fi
if [[ -n ${UKE_TOUCH_NORMAL_IMAGE:-} ]]; then
    [[ -f $UKE_TOUCH_NORMAL_IMAGE ]]
    "${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -I "$stage" \
        "$root/tests/touch-protocol-firmware.c" "$root/src/input/nt36532-uke-protocol.c" \
        "${sanitize[@]}" -lcrypto -o "$stage/firmware"
    "$stage/firmware" "$UKE_TOUCH_NORMAL_IMAGE" "${UKE_TOUCH_NORMAL_VARIANT:-csot}"
fi
