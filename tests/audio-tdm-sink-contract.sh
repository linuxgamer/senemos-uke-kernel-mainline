#!/usr/bin/env bash
# Actual TDM sink parameter encoder and topology token loader with host mocks;
# no DSP, GPR transport or interface access. Values mirror stock ACDB graph
# a2000001 (metadata only): LPAIF type 3, index 0, four 32-bit slots, lane mask 2.
set -Eeuo pipefail
kernel=${1:?Pass prepared kernel tree}
q6=$kernel/sound/soc/qcom/qdsp6
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
extract_block() {  # file, start regex, closing regex
    awk -v start="$2" -v stop="$3" '$0 ~ start {emit=1} emit {print} emit && $0 ~ stop {exit}' "$1"
}
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uint8_t u8; typedef uint16_t u16; typedef uint32_t u32;
#define __packed __attribute__((packed))
#define __init
#define ALIGN(x, a) (((x) + (a) - 1) & ~((a) - 1))
#define U16_MAX 0xffff
#define le32_to_cpu(x) (x)
#define __free(f) __attribute__((cleanup(f##_cleanup)))
#define IS_ERR(p) ((uintptr_t)(p) >= (uintptr_t)-4095)
static void kfree_cleanup(void *p) { void *v = *(void **)p; if (v && !IS_ERR(v)) free(v); }
#define PTR_ERR(p) ((long)(p))
struct gpr_hdr { uint32_t b0, b1, src_port, dest_port, token, opcode; } __packed;
#define GPR_HDR_SIZE sizeof(struct gpr_hdr)
struct gpr_pkt { struct gpr_hdr hdr; uint32_t payload[]; };
struct apm_cmd_header { uint32_t payload_address_lsw, payload_address_msw, mem_map_handle, payload_size; } __packed;
#define APM_CMD_HDR_SIZE sizeof(struct apm_cmd_header)
struct apm_module_param_data { uint32_t module_instance_id, param_id, param_size, error_code; } __packed;
#define APM_MODULE_PARAM_DATA_SIZE sizeof(struct apm_module_param_data)
#define APM_CMD_SET_CFG 0x01001006
struct q6apm; struct q6apm_graph { struct q6apm *apm; };
struct audioreach_module {
    uint32_t instance_id, hw_interface_idx, hw_interface_type, data_format, slot_mask,
             active_lane_mask;
    u16 sync_src, ctrl_data_out_enable, nslots_per_frame, slot_width, sync_mode,
        ctrl_invert_sync_pulse, ctrl_sync_data_delay;
};
struct audioreach_module_config {
    u32 sample_rate; u16 bit_width, num_channels; u32 slot_mask; u16 nslots_per_frame, slot_width;
};
static unsigned char sent[512]; static size_t sent_size; static unsigned sends; static bool fail_alloc;
static int send_status;
static void *audioreach_alloc_apm_cmd_pkt(int pkt_size, uint32_t opcode, uint32_t token) {
    if (fail_alloc) return (void *)(uintptr_t)-ENOMEM;
    size_t total = GPR_HDR_SIZE + APM_CMD_HDR_SIZE + pkt_size;
    struct gpr_pkt *pkt = calloc(1, total);
    pkt->hdr.opcode = opcode; pkt->hdr.token = token; pkt->hdr.b1 = total;
    return pkt;
}
static int q6apm_send_cmd_sync(struct q6apm *apm, struct gpr_pkt *pkt, uint32_t rsp) {
    (void)apm; (void)rsp;
    sent_size = pkt->hdr.b1; assert(sent_size <= sizeof(sent));
    memcpy(sent, pkt, sent_size); sends++;
    return send_status;
}
C
{
    extract_block "$q6/audioreach.h" '^#define PARAM_ID_TDM_INTF_CFG' '^#define AR_HW_EP_CLK_ATTR_DEFAULT'
    # The first block above already carries the interface and lane structures.
    for s in param_id_hw_ep_clk_attr param_id_hw_ep_mf; do
        extract_block "$q6/audioreach.h" "^struct $s [{]" '^} __packed;'
    done
    printf '#define PARAM_ID_TDM_LANE_CFG 0x0800106A\n#define PARAM_ID_HW_EP_CLK_ATTR_CFG 0x0800113C\n#define PARAM_ID_HW_EP_MF_CFG 0x08001017\n'
    for s in apm_tdm_module_intf_cfg apm_tdm_module_lane_cfg apm_module_hw_ep_clk_attr_cfg apm_module_hw_ep_mf_cfg apm_module_frame_size_factor_cfg; do
        extract_block "$q6/audioreach.c" "^struct $s [{]" '^#define|^} __packed;'
    done
    for m in APM_TDM_INTF_CFG_PSIZE APM_TDM_LANE_CFG_PSIZE APM_HW_EP_CLK_ATTR_PSIZE APM_HW_EP_CFG_PSIZE APM_FS_CFG_PSIZE; do
        grep -E "^#define $m " "$q6/audioreach.c"
    done
    extract_block "$q6/audioreach.c" '^static int audioreach_tdm_set_media_format' '^}'
} | grep -v '^#define PARAM_ID_TDM_LANE_CFG\|^#define PARAM_ID_HW_EP_CLK_ATTR_CFG\|^#define PARAM_ID_HW_EP_MF_CFG' >> "$work/body.c"
# Parameter ids come from the real header lines, not from the harness.
grep -E '^#define (PARAM_ID_TDM_INTF_CFG|PARAM_ID_TDM_LANE_CFG|PARAM_ID_HW_EP_CLK_ATTR_CFG|AR_HW_EP_CLK_ATTR_DEFAULT)\b' "$q6/audioreach.h" >> "$work/defs.c"
grep -E '^#define (PARAM_ID_HW_EP_MF_CFG|PARAM_ID_HW_EP_FRAME_SIZE_FACTOR)\b' "$q6/audioreach.h" >> "$work/defs.c"
cat "$work/defs.c" "$work/body.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'

static const unsigned char *block(unsigned index, struct apm_module_param_data *head, size_t *offset) {
    /* Skip the GPR and APM headers, then walk 8-byte aligned parameter blocks. */
    static size_t cursor; if (index == 0) cursor = GPR_HDR_SIZE + APM_CMD_HDR_SIZE;
    memcpy(head, sent + cursor, sizeof *head);
    const unsigned char *payload = sent + cursor + sizeof *head;
    *offset = cursor;
    cursor += sizeof *head + ALIGN(head->param_size, 8) - ALIGN(0, 8);
    return payload;
}
static uint32_t word(const unsigned char *p, unsigned i) { uint32_t v; memcpy(&v, p + 4 * i, 4); return v; }
static uint16_t half(const unsigned char *p, unsigned i) { uint16_t v; memcpy(&v, p + 2 * i, 2); return v; }

int main(void) {
    struct audioreach_module module = {
        .instance_id = 0x6111, .hw_interface_idx = 0, .hw_interface_type = 3, .data_format = 1,
        .slot_mask = 15, .active_lane_mask = 2, .sync_src = 1, .ctrl_data_out_enable = 1,
        .nslots_per_frame = 4, .slot_width = 32, .sync_mode = 0, .ctrl_invert_sync_pulse = 0,
        .ctrl_sync_data_delay = 1,
    };
    struct audioreach_module_config cfg = { .sample_rate = 48000, .bit_width = 32, .num_channels = 4 };
    struct q6apm_graph graph = { 0 };
    struct apm_module_param_data head; size_t offset;

    assert(audioreach_tdm_set_media_format(&graph, &module, &cfg) == 0 && sends == 1);
    assert(((struct gpr_pkt *)sent)->hdr.opcode == APM_CMD_SET_CFG);

    /* 1: interface configuration, 28 bytes in a 48-byte block. */
    const unsigned char *p = block(0, &head, &offset);
    assert(head.module_instance_id == 0x6111 && head.param_id == 0x0800101b && head.error_code == 0);
    assert(head.param_size == 32);
    assert(word(p, 0) == 3 && word(p, 1) == 0);                 /* lpaif type VA, index 0 */
    assert(half(p, 4) == 1 && half(p, 5) == 1);                 /* sync source, data out */
    assert(word(p, 3) == 15);                                   /* four active slots */
    assert(half(p, 8) == 4 && half(p, 9) == 32);                /* slots per frame, slot width */
    assert(half(p, 10) == 0 && half(p, 11) == 0 && half(p, 12) == 1 && half(p, 13) == 0);
    /* 2: lane mask. */
    p = block(1, &head, &offset);
    assert(head.param_id == 0x0800106a && head.param_size == 8 && word(p, 0) == 2);
    /* 3: hardware endpoint media format. */
    p = block(2, &head, &offset);
    assert(head.param_id == 0x08001017 && word(p, 0) == 48000);
    assert(half(p, 2) == 32 && half(p, 3) == 4 && word(p, 2) == 1);
    /* 4: frame size factor, which the stock graph also sends to the TDM endpoint. */
    p = block(3, &head, &offset);
    assert(head.param_id == 0x08001018 && head.param_size == 8 && word(p, 0) == 1);
    /* 5: interface clock attributes as the stock graph sends them. */
    p = block(4, &head, &offset);
    assert(head.param_id == 0x0800113c && head.param_size == 16);
    assert(word(p, 0) == 0 && word(p, 1) == 0 && word(p, 2) == 4 && word(p, 3) == 0);
    assert(offset + sizeof head + 16 == sent_size);             /* nothing trailing */

    /* A stream-level slot configuration overrides the module defaults. */
    cfg.slot_mask = 3; cfg.nslots_per_frame = 2; cfg.slot_width = 16;
    cfg.num_channels = 2; cfg.bit_width = 16;
    assert(audioreach_tdm_set_media_format(&graph, &module, &cfg) == 0);
    p = block(0, &head, &offset);
    assert(word(p, 3) == 3 && half(p, 8) == 2 && half(p, 9) == 16);

    const struct audioreach_module_config valid = cfg;
    for (unsigned fault = 0; fault < 7; fault++) {
        cfg = valid;
        if (fault == 0) cfg.nslots_per_frame = 33;
        if (fault == 1) cfg.slot_width = 33;
        if (fault == 2) cfg.slot_mask = 4;
        if (fault == 3) cfg.num_channels = 3;
        if (fault == 4) cfg.bit_width = 32;
        if (fault == 5) cfg.sample_rate = 0;
        if (fault == 6) cfg.num_channels = 0;
        sends = 0;
        assert(audioreach_tdm_set_media_format(&graph, &module, &cfg) == -EINVAL && sends == 0);
    }
    cfg = valid; send_status = -EIO;
    assert(audioreach_tdm_set_media_format(&graph, &module, &cfg) == -EIO);
    send_status = 0;

    /* Allocation failure is propagated and nothing is sent. */
    fail_alloc = true; sends = 0;
    assert(audioreach_tdm_set_media_format(&graph, &module, &cfg) == -ENOMEM && sends == 0);
    printf("TDM sink parameter fixtures passed\n");
    return 0;
}
C
cc=${CC:-clang}
flags=(-O1 -g -Wall -Wno-unused-function -Wno-unused-parameter -Wno-unused-variable)
if ! $cc "${flags[@]}" -fsanitize=address,undefined -fno-sanitize-recover=undefined -o "$work/check" "$work/check.c" 2>"$work/cc.log"; then
    $cc "${flags[@]}" -fsanitize=undefined -fsanitize-trap=all -o "$work/check" "$work/check.c" 2>"$work/cc.log" || { cat "$work/cc.log" >&2; exit 1; }
fi
"$work/check"
# Topology loader: the TDM module must be routed to its own token parser.
awk '/^static int audioreach_widget_load_buffer\(/ {emit=1} emit {print} emit && /^}/ {exit}' "$q6/topology.c" > "$work/load.c"
grep -Fq 'case MODULE_ID_TDM_SINK:' "$work/load.c"
grep -Fq 'audioreach_widget_tdm_module_load(mod, mod_array)' "$work/load.c"
for token in HW_IF_IDX HW_IF_TYPE SYNC_SRC CTRL_DATA_OUT_ENABLE SLOT_MASK NSLOTS_PER_FRAME SLOT_WIDTH \
             SYNC_MODE CTRL_INVERT_SYNC_PULSE CTRL_SYNC_DATA_DELAY ACTIVE_LANE_MASK FMT_DATA; do
    extract_block "$q6/topology.c" '^static int audioreach_widget_tdm_module_load' '^}' | grep -Fq "_MODULE_$token:"
done
