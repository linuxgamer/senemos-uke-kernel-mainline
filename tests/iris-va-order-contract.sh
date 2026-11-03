#!/usr/bin/env bash
# Compile the actual opt-in property function with a fault-injected HFI writer.
set -Eeuo pipefail
iris=${1:?Pass the prepared Iris directory}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cerrno>
#include <cstdint>
using u32 = uint32_t;
enum { DISPLAY_DELAY_ENABLE, CAP_FLAG_CLIENT_SET = 2, HFI_HOST_FLAGS_NONE = 0,
       HFI_PORT_BITSTREAM = 1, HFI_PAYLOAD_U32 = 4, HFI_PROP_DECODE_ORDER_OUTPUT = 0x0300015b };
struct platform_inst_fw_cap { u32 value, flags; };
struct iris_inst { platform_inst_fw_cap fw_caps[1]; };
static unsigned writes, last;
static int failure;
static int iris_hfi_gen2_session_set_property(iris_inst *, u32 property, u32 flags,
                                             u32 port, u32 payload, void *data, u32 size) {
    assert(property == HFI_PROP_DECODE_ORDER_OUTPUT && flags == HFI_HOST_FLAGS_NONE);
    assert(port == HFI_PORT_BITSTREAM && payload == HFI_PAYLOAD_U32 && size == sizeof(u32));
    ++writes; last = *static_cast<u32 *>(data); return failure;
}
CPP
awk '/^static int iris_hfi_gen2_set_decode_order_output\(/ { emit=1 } emit { print } emit && /^}/ { exit }' \
    "$iris/iris_hfi_gen2_command.c" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
int main() {
    iris_inst inst{};
    assert(iris_hfi_gen2_set_decode_order_output(&inst, 0) == 0 && writes == 0);
    inst.fw_caps[0] = {1, CAP_FLAG_CLIENT_SET};
    assert(iris_hfi_gen2_set_decode_order_output(&inst, 0) == 0 && writes == 1 && last == 1);
    inst.fw_caps[0].value = 0;
    assert(iris_hfi_gen2_set_decode_order_output(&inst, 0) == 0 && writes == 2 && last == 0);
    failure = -EREMOTEIO;
    assert(iris_hfi_gen2_set_decode_order_output(&inst, 0) == -EREMOTEIO && writes == 3);
}
CPP
"${CXX:-g++}" -std=c++17 -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
    "$work/check.cpp" -o "$work/check"
"$work/check"
printf 'Actual HFI decode order: unchanged default, opt-in, restore and error propagation passed\n'
