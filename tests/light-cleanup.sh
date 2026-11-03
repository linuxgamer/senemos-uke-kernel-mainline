#!/usr/bin/env bash
# Exercise the actual upstream cleanup with empty, torch-only and mixed slots.
set -Eeuo pipefail
source=${1:?Pass the patched leds-qcom-flash.c}
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
cat > "$stage/test.c" <<'C'
#include <assert.h>
#include <stdlib.h>
struct qcom_flash_data { unsigned leds_count; void **v4l2_flash; };
static unsigned released;
static void v4l2_flash_release(void *p) { assert(p); ++released; }
C
awk '/^static void qcom_flash_release\(/ {copy=1} copy {print} copy && /^}/ {exit}' "$source" >> "$stage/test.c"
grep -q '^static void qcom_flash_release(' "$stage/test.c"
cat >> "$stage/test.c" <<'C'
int main(void) {
    for (unsigned n=0; n<=4; ++n) for (unsigned mask=0; mask<(1U<<n); ++mask) {
        struct qcom_flash_data d={n, calloc(n, sizeof(void*))};
        unsigned expected=0;
        for (unsigned i=0; i<n; ++i) if (mask & (1U<<i)) { d.v4l2_flash[i]=&released; ++expected; }
        released=0; qcom_flash_release(&d);
        assert(d.leds_count==0 && released==expected);
        qcom_flash_release(&d); assert(released==expected);
        free(d.v4l2_flash);
    }
}
C
${CC:-cc} -std=c11 -Wall -Wextra -Werror -fsanitize=address -fno-omit-frame-pointer "$stage/test.c" -o "$stage/test"
"$stage/test"
printf '%s\n' 'Actual QCOM cleanup: zero through four torch/flash slots and repeated release: PASS'
