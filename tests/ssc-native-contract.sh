#!/usr/bin/env bash
# Actual callbacks with fake providers and the unchanged upstream QMI encoder.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
kernel=${1:?Pass the pinned upstream kernel source in the remote worker}
test ! -e /etc/senemos/kernel-update.conf
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
mkdir -p "$stage/include/linux/soc/qcom"
cat > "$stage/include/linux/types.h" <<'TYPES'
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int16_t s16;
typedef int32_t s32;
typedef int64_t s64;
typedef uint16_t __le16;
typedef uint32_t __le32;
typedef uint64_t __le64;
TYPES
cat > "$stage/include/linux/soc/qcom/qmi.h" <<'QMI'
/* Host declarations matching the pinned Linux QMI public interface. */
#include <linux/types.h>
struct qmi_header { u8 type; __le16 txn_id, msg_id, msg_len; } __attribute__((packed));
#define QMI_REQUEST 0
#define QMI_RESPONSE 2
#define QMI_INDICATION 4
#define QMI_COMMON_TLV_TYPE 0
enum qmi_elem_type { QMI_EOTI,QMI_OPT_FLAG,QMI_DATA_LEN,QMI_UNSIGNED_1_BYTE,
 QMI_UNSIGNED_2_BYTE,QMI_UNSIGNED_4_BYTE,QMI_UNSIGNED_8_BYTE,
 QMI_SIGNED_2_BYTE_ENUM,QMI_SIGNED_4_BYTE_ENUM,QMI_STRUCT,QMI_STRING };
enum qmi_array_type { NO_ARRAY,STATIC_ARRAY,VAR_LEN_ARRAY };
struct qmi_elem_info { enum qmi_elem_type data_type; u32 elem_len,elem_size;
 enum qmi_array_type array_type; u8 tlv_type; u32 offset; const struct qmi_elem_info *ei_array; };
struct qmi_response_type_v01 { u16 result,error; };
extern const struct qmi_elem_info qmi_response_type_v01_ei[];
void *qmi_encode_message(int, unsigned int, size_t *, unsigned int, const struct qmi_elem_info *, const void *);
int qmi_decode_message(const void *, size_t, const struct qmi_elem_info *, void *);
QMI
for header in slab uaccess module kernel string; do
    printf '#include "ssc-native-host.h"\n' > "$stage/include/linux/$header.h"
done
cp "$root/tests/ssc-native-host.h" "$stage/include/ssc-native-host.h"
{
    printf '#define UKE_SSC_NATIVE_CALLBACKS 1\n#include "ssc-native-host.h"\n#include <linux/soc/qcom/qmi.h>\n#include "uke-ssc-protocol.h"\n'
    awk '/^#define SSC_SERVICE /{emit=1} /^static bool ssc_uid_equal\(/{exit} emit{print}' \
        "$root/src/sensors/uke-ssc-iio.c"
    printf '%s\n' 'static void ssc_close_client(struct ssc_controller *c);'
    for name in ssc_uid_equal ssc_current ssc_observe ssc_record_failure ssc_failure_name ssc_schedule_locked ssc_invalidate_locked \
        ssc_response ssc_request ssc_rate ssc_sample_values ssc_attributes_usable ssc_read_scale ssc_report ssc_message \
        ssc_start ssc_stop ssc_close_client; do
        awk -v name="$name" '
          $0 ~ "^static .*([[:space:]]|[*])" name "\\(" && $0 !~ /;/ {emit=1;found=1}
          emit {print}
          emit && /^}/ {emit=0;exit}
          END {if(!found)exit 1}
        ' "$root/src/sensors/uke-ssc-iio.c"
    done
    awk '
      /^#define SSC_OBSERVATION_ATTRIBUTE\(/ {emit=1;found=1}
      emit {print}
      /^ATTRIBUTE_GROUPS\(ssc_observation\);$/ {done=1;exit}
      END {if(!found || !done)exit 1}
    ' "$root/src/sensors/uke-ssc-iio.c"
    printf '%s\n' 'static const int ssc_client_ops;'
    awk '
      /^static void ssc_reconcile\(/ {emit=1;found=1}
      emit {print}
      emit && /^}/ {done=1;exit}
      END {if(!found || !done)exit 1}
    ' "$root/src/sensors/uke-ssc-iio.c"
    [[ $(grep -Fc '.dev_groups = ssc_observation_groups' "$root/src/sensors/uke-ssc-iio.c") == 1 ]]
    cat "$root/tests/ssc-native-contract.c"
} > "$stage/check.c"
# The upstream QMI helper intentionally performs unaligned typed wire accesses.
# Preserve that source and disable only its host alignment instrumentation.
for compiler in gcc clang; do
    common=(-std=gnu11 -O1 -g -UNDEBUG -Wall -Werror -Wno-unused-parameter
        -fsanitize=address,undefined -fno-omit-frame-pointer
        -I"$stage/include" -I"$root/src/sensors")
    "$compiler" "${common[@]}" -fno-sanitize=alignment -Dqmi_decode_message=upstream_qmi_decode_message -c \
        "$kernel/drivers/soc/qcom/qmi_encdec.c" -o "$stage/qmi.o"
    "$compiler" "${common[@]}" "$stage/check.c" \
        "$root/src/sensors/uke-ssc-protocol.c" "$stage/qmi.o" -o "$stage/check"
    ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 "$stage/check"
    # Restore only the former production guard. Positive IDs must expose it
    # with the same real callback fixture under both compilers/sanitizers.
    sed '/ret = qmi_txn_init(&c->client, &txn, NULL, NULL);/,/return ret;/s/if (ret < 0)/if (ret)/' \
        "$stage/check.c" > "$stage/positive-id-negative.c"
    ! cmp -s "$stage/check.c" "$stage/positive-id-negative.c"
    "$compiler" "${common[@]}" "$stage/positive-id-negative.c" \
        "$root/src/sensors/uke-ssc-protocol.c" "$stage/qmi.o" -o "$stage/positive-id-negative"
    if (ulimit -c 0; ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
        "$stage/positive-id-negative") > "$stage/positive-id-negative.log" 2>&1; then
        printf 'SSC fixture missed the former positive transaction-ID refusal\n' >&2
        exit 1
    fi
    grep -q 'Assertion.*failed' "$stage/positive-id-negative.log"
    printf 'Actual SSC original guard rejected by positive transaction-ID control: %s\n' "$compiler"
    if [[ $compiler == gcc ]]; then
        for fault in stale-error stale-status; do
            if [[ $fault == stale-error ]]; then
                sed 's/!c->removed && c->generation == generation/!c->removed/' \
                    "$stage/check.c" > "$stage/negative.c"
            else
                sed 's/if (out->connected)/if (true)/' \
                    "$stage/check.c" > "$stage/negative.c"
            fi
            ! cmp -s "$stage/check.c" "$stage/negative.c"
            "$compiler" "${common[@]}" "$stage/negative.c" \
                "$root/src/sensors/uke-ssc-protocol.c" "$stage/qmi.o" -o "$stage/negative"
            if (ulimit -c 0; ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
                "$stage/negative") > "$stage/negative.log" 2>&1; then
                printf 'SSC observation fixture missed %s\n' "$fault" >&2
                exit 1
            fi
            grep -q 'Assertion.*failed' "$stage/negative.log"
            printf 'Actual SSC observation negative control detected %s\n' "$fault"
        done
    fi
done
