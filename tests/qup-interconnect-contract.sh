#!/usr/bin/env bash
# Compile the actual kernel C graph and verify QUP/LPASS routes on the host.
set -Eeuo pipefail
source_file=${1:?Pass the prepared qnoc-cliffs-usb.c}
expect_cdsp=${2:-0}
case $expect_cdsp in 0|1) ;; *) exit 2;; esac
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
{
    printf '#define EXPECT_CDSP %s\n' "$expect_cdsp"
    cat <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
struct regmap_config { unsigned int reg_bits, reg_stride, val_bits; };
struct qcom_icc_qosbox {
    unsigned int num_ports, port_offsets[2], prio, urg_fwd, prio_fwd_disable;
};
struct qcom_icc_node {
    const char *name;
    unsigned int channels, buswidth, num_links;
    const struct qcom_icc_qosbox *qosbox;
    struct qcom_icc_node *link_nodes[64];
};
struct qcom_icc_bcm {
    const char *name;
    bool keepalive;
    unsigned int vote_scale, enable_mask, num_nodes;
    struct qcom_icc_node *nodes[64];
};
struct qcom_icc_desc {
    const struct regmap_config *config;
    struct qcom_icc_node * const *nodes;
    size_t num_nodes;
    struct qcom_icc_bcm * const *bcms;
    size_t num_bcms;
    bool qos_required, qos_requires_clocks;
};
C
    awk '/^#define MASTER_APPSS_PROC/ { emit=1 } /^static const struct of_device_id/ { emit=0 } emit { print }' "$source_file"
    cat <<'C'
static const struct qcom_icc_desc *providers[] = {
    &cliffs_aggre1_noc, &cliffs_aggre2_noc, &cliffs_clk_virt,
    &cliffs_cnoc_cfg, &cliffs_cnoc_main, &cliffs_gem_noc,
    &cliffs_mc_virt, &cliffs_system_noc, &cliffs_mmss_noc,
    &cliffs_lpass_ag_noc, &cliffs_lpass_lpiaon_noc, &cliffs_lpass_lpicx_noc,
#if EXPECT_CDSP
    &cliffs_nsp_noc,
#endif
};
static bool registered(const struct qcom_icc_node *node) {
    for (size_t p = 0; p < ARRAY_SIZE(providers); ++p)
        for (size_t i = 0; i < providers[p]->num_nodes; ++i)
            if (providers[p]->nodes[i] == node) return true;
    return false;
}
static bool reaches(const struct qcom_icc_node *from, const struct qcom_icc_node *to, int depth) {
    assert(from && registered(from) && depth < 16);
    if (from == to) return true;
    for (unsigned int i = 0; i < from->num_links; ++i)
        if (reaches(from->link_nodes[i], to, depth + 1)) return true;
    return false;
}
int main(void) {
    for (size_t p = 0; p < ARRAY_SIZE(providers); ++p) {
        const struct qcom_icc_desc *provider = providers[p];
        for (size_t i = 0; i < provider->num_nodes; ++i) {
            const struct qcom_icc_node *node = provider->nodes[i];
            if (!node) continue;
            assert(node->channels && node->buswidth && node->num_links <= 64);
            for (unsigned int j = 0; j < node->num_links; ++j)
                assert(node->link_nodes[j] && registered(node->link_nodes[j]));
        }
        for (size_t i = 0; i < provider->num_bcms; ++i)
            for (unsigned int j = 0; j < provider->bcms[i]->num_nodes; ++j)
                assert(registered(provider->bcms[i]->nodes[j]));
    }
    assert(reaches(&qup0_core_master, &qup0_core_slave, 0));
    assert(reaches(&qup1_core_master, &qup1_core_slave, 0));
    assert(reaches(&chm_apps, &qhs_qup0, 0));
    assert(reaches(&chm_apps, &qhs_qup1, 0));
    assert(gem_noc_nodes[MASTER_GFX3D] == &qnm_gpu);
    assert(reaches(&qnm_gpu, &ebi, 0));
    assert(reaches(&qnm_gpu, &qss_cfg, 0));
    assert(qnm_gpu.channels == 2 && qnm_gpu.buswidth == 32);
    assert(qnm_gpu.qosbox == &qnm_gpu_qos && qnm_gpu_qos.num_ports == 2);
    assert(qnm_gpu_qos.port_offsets[0] == 0x31000 && qnm_gpu_qos.port_offsets[1] == 0x71000);
    assert(!qnm_gpu_qos.prio && !qnm_gpu_qos.urg_fwd && qnm_gpu_qos.prio_fwd_disable);
    assert(bcm_sh1.num_nodes == 6 + EXPECT_CDSP && bcm_sh1.nodes[1] == &qnm_gpu);
    assert(bcm_sh1.nodes[4] == &qnm_mnoc_hf && bcm_sh1.nodes[5] == &qnm_mnoc_sf);
    assert(reaches(&qhm_qup0, &ebi, 0));
    assert(reaches(&qhm_qup1, &ebi, 0));
    assert(reaches(&xm_usb3_0, &ebi, 0));
    assert(reaches(&xm_ufs_mem, &ebi, 0));
    assert(!reaches(&qup1_core_master, &qhs_qup0, 0));
    assert(cliffs_aggre2_noc.qos_required && cliffs_aggre2_noc.qos_requires_clocks);
    assert(qhm_qup1_qos.port_offsets[0] == 0x13000 && qhm_qup1_qos.prio == 2);
    assert(bcm_qup1.keepalive && bcm_qup1.vote_scale == 1);
    assert(lpass_lpicx_noc_nodes[40] == &qxm_lpinoc_dsp_axim);
    assert(lpass_lpicx_noc_nodes[558] == &qns_lpi_aon_noc);
    assert(lpass_lpiaon_noc_nodes[19] == &qnm_lpass_lpinoc);
    assert(lpass_lpiaon_noc_nodes[557] == &qns_lpass_aggnoc);
    assert(lpass_ag_noc_nodes[20] == &qnm_lpiaon_noc);
    assert(lpass_ag_noc_nodes[556] == &qns_lpass_ag_noc_gemnoc);
    assert(gem_noc_nodes[18] == &qnm_lpass_gemnoc);
    assert(reaches(&qxm_lpinoc_dsp_axim, &ebi, 0));
    assert(!reaches(&qxm_lpinoc_dsp_axim, &xm_ufs_mem, 0));
    assert(qnm_lpass_gemnoc_qos.port_offsets[0] == 0xb5000);
    assert(qnm_lpass_gemnoc_qos.prio == 0 && qnm_lpass_gemnoc_qos.urg_fwd == 1);
    assert(qnm_lpass_gemnoc_qos.prio_fwd_disable == 0);
    assert(!cliffs_lpass_ag_noc.num_bcms && !cliffs_lpass_lpicx_noc.num_bcms);
    assert(cliffs_lpass_lpiaon_noc.num_bcms == 1);
    assert(cliffs_lpass_lpiaon_noc.bcms[0] == &bcm_lp0);
    assert(!bcm_lp0.keepalive && !bcm_lp0.enable_mask && bcm_lp0.num_nodes == 2);
    assert(bcm_lp0.nodes[0] == &qnm_lpass_lpinoc);
    assert(bcm_lp0.nodes[1] == &qns_lpass_aggnoc);
    for (unsigned int i = 0; i < bcm_sh1.num_nodes; ++i)
        assert(bcm_sh1.nodes[i] != &qnm_lpass_gemnoc);
#if EXPECT_CDSP
    assert(nsp_noc_nodes[41] == &qxm_nsp && nsp_noc_nodes[561] == &qns_nsp_gemnoc);
    assert(gem_noc_nodes[25] == &qnm_nsp_gemnoc);
    assert(qxm_nsp.channels == 2 && qxm_nsp.buswidth == 32);
    assert(qxm_nsp.num_links == 1 && qxm_nsp.link_nodes[0] == &qns_nsp_gemnoc);
    assert(qns_nsp_gemnoc.num_links == 1 && qns_nsp_gemnoc.link_nodes[0] == &qnm_nsp_gemnoc);
    assert(qnm_nsp_gemnoc.channels == 2 && qnm_nsp_gemnoc.buswidth == 32);
    assert(qnm_nsp_gemnoc.qosbox == &qnm_nsp_gemnoc_qos);
    assert(qnm_nsp_gemnoc_qos.num_ports == 2);
    assert(qnm_nsp_gemnoc_qos.port_offsets[0] == 0x37000 && qnm_nsp_gemnoc_qos.port_offsets[1] == 0x77000);
    assert(!qnm_nsp_gemnoc_qos.prio && !qnm_nsp_gemnoc_qos.urg_fwd && qnm_nsp_gemnoc_qos.prio_fwd_disable == 1);
    assert(reaches(&qxm_nsp, &ebi, 0));
    assert(!reaches(&qxm_nsp, &xm_usb3_0, 0) && !reaches(&qxm_nsp, &xm_ufs_mem, 0));
    assert(bcm_co0.num_nodes == 2 && bcm_co0.enable_mask == 1);
    assert(bcm_co0.nodes[0] == &qxm_nsp && bcm_co0.nodes[1] == &qns_nsp_gemnoc);
    unsigned int nsp_members = 0;
    for (unsigned int i=0; i<bcm_sh1.num_nodes; i++) nsp_members += bcm_sh1.nodes[i] == &qnm_nsp_gemnoc;
    assert(nsp_members == 1 && bcm_sh1.num_nodes == 7);
    assert(bcm_sh1.nodes[4] == &qnm_mnoc_hf && bcm_sh1.nodes[5] == &qnm_mnoc_sf);
    assert(aggre2_noc_nodes[38] == &qxm_crypto);
    assert(qxm_crypto.channels == 1 && qxm_crypto.buswidth == 8);
    assert(qxm_crypto.qosbox == &qxm_crypto_qos);
    assert(qxm_crypto_qos.num_ports == 1 && qxm_crypto_qos.port_offsets[0] == 0x15000);
    assert(qxm_crypto_qos.prio == 2 && !qxm_crypto_qos.urg_fwd && qxm_crypto_qos.prio_fwd_disable == 1);
    assert(reaches(&qxm_crypto, &ebi, 0));
    assert(!reaches(&qxm_crypto, &xm_usb3_0, 0) && !reaches(&qxm_crypto, &xm_ufs_mem, 0));
    assert(cliffs_aggre2_noc.num_bcms == 1 && cliffs_aggre2_noc.bcms[0] == &bcm_ce0);
    assert(!bcm_ce0.keepalive && !bcm_ce0.enable_mask && bcm_ce0.num_nodes == 1 && bcm_ce0.nodes[0] == &qxm_crypto);
#endif
}
C
} > "$work/check.c"
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -I "$(dirname "$source_file")" "$work/check.c" -o "$work/check"
"$work/check"
printf 'Registered QUP/LPASS and selected CDSP/crypto graph, BCM/QoS and USB/UFS/display membership: passed (CDSP=%s)\n' "$expect_cdsp"
