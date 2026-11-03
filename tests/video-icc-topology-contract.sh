#!/usr/bin/env bash
# Exercise pointer routes from the actual candidate header, without hardware I/O.
set -Eeuo pipefail
kernel=${1:?Pass the prepared kernel source}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <string.h>
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
struct qcom_icc_qosbox {
    unsigned num_ports, port_offsets[4], prio, urg_fwd, prio_fwd_disable;
};
struct qcom_icc_node {
    const char *name;
    unsigned channels, buswidth;
    const struct qcom_icc_qosbox *qosbox;
    unsigned num_links;
    struct qcom_icc_node *link_nodes[16];
};
struct qcom_icc_bcm {
    const char *name;
    unsigned enable_mask, num_nodes;
    struct qcom_icc_node *nodes[16];
};
struct qcom_icc_desc {
    const void *config;
    struct qcom_icc_node *const *nodes;
    unsigned num_nodes;
    struct qcom_icc_bcm *const *bcms;
    unsigned num_bcms;
    bool qos_required;
};
static int cliffs_icc_regmap_config;
static struct qcom_icc_node qns_gem_noc_cnoc = {.name = "config"};
static struct qcom_icc_node qns_llcc = {.name = "shared DDR"};
#include "cliffs-display-icc.h"
static bool reaches(struct qcom_icc_node *from, struct qcom_icc_node *to, unsigned depth) {
    if (from == to) return true;
    if (!depth) return false;
    assert(from->num_links <= ARRAY_SIZE(from->link_nodes));
    for (unsigned i = 0; i < from->num_links; ++i)
        if (reaches(from->link_nodes[i], to, depth - 1)) return true;
    return false;
}
int main(void) {
    assert(MASTER_VIDEO == 28 && MASTER_MNOC_SF_MEM_NOC == 24 && SLAVE_VENUS_CFG == 548);
    assert(cliffs_mmss_noc.nodes[MASTER_VIDEO] == &qnm_video);
    assert(reaches(&qnm_video, &qns_llcc, 4));
    assert(reaches(&qnm_video, &qns_gem_noc_cnoc, 4));
    assert(reaches(&qnm_mdp, &qns_llcc, 4));
    assert(qnm_video.channels == 1 && qnm_video.buswidth == 32);
    assert(qnm_video.qosbox->port_offsets[0] == 0x30000);
    assert(qnm_mnoc_sf.qosbox->num_ports == 2);
    assert(qnm_mnoc_sf.qosbox->port_offsets[0] == 0x35000);
    assert(qnm_mnoc_sf.qosbox->port_offsets[1] == 0x75000);
    assert(bcm_mm1.enable_mask == 1 && bcm_mm1.num_nodes == 1);
    assert(bcm_mm1.nodes[0] == &qns_mem_noc_sf);
    assert(qhs_venus_cfg.buswidth == 4 && !qhs_venus_cfg.num_links);
    assert(qhs_display_cfg.buswidth == 4 && !qhs_display_cfg.num_links);
}
C
"${CC:-gcc}" -std=gnu11 -O2 -Wall -Wextra -Werror \
    -I "$kernel/drivers/interconnect/qcom" "$work/check.c" -o "$work/check"
"$work/check"
printf 'Actual Cliffs video/display DDR routes, configuration endpoint and OEM QoS/BCM passed\n'
