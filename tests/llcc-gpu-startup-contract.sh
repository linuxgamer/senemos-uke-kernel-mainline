#!/usr/bin/env bash
# Actual Adreno probe and supplier helper; no driver-core or hardware emulation.
set -Eeuo pipefail
source_file=${1:?Pass prepared adreno_device.c}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#define EPROBE_DEFER 517
#define DL_FLAG_AUTOREMOVE_CONSUMER 16U
struct device_node { bool gpu, imageon, enabled; };
struct device { struct device_node *of_node; };
struct platform_device { struct device dev; };
struct device_link { int unused; };
static struct device_node supplier_node;
static struct platform_device supplier;
static struct device_link link;
static int a3xx_ops;
static bool node_present, device_present, bound, link_failure, unbind_during_link, no_components;
static int node_refs, device_refs, node_gets, device_gets, link_calls, bound_checks;
static int component_calls, standalone_calls, downstream_error;
static inline bool of_device_is_compatible(struct device_node *n, const char *name) {
    assert(n); return !strcmp(name,"qcom,adreno-43030b00") ? n->gpu : n->imageon;
}
static inline struct device_node *of_find_compatible_node(void *from, void *type, const char *name) {
    assert(!from && !type && !strcmp(name,"qcom,sm7675-llcc")); node_gets++;
    if (!node_present) return NULL;
    node_refs++; return &supplier_node;
}
static inline bool of_device_is_available(struct device_node *n) { assert(n==&supplier_node && node_refs==1); return n->enabled; }
static inline void of_node_put(struct device_node *n) { assert(n==&supplier_node && node_refs==1); node_refs--; }
static inline struct platform_device *of_find_device_by_node(struct device_node *n) {
    assert(n==&supplier_node && node_refs==1); device_gets++;
    if (!device_present) return NULL;
    device_refs++; return &supplier;
}
static inline struct device_link *device_link_add(struct device *consumer, struct device *provider, unsigned int flags) {
    assert(consumer!=provider && provider==&supplier.dev && device_refs==1);
    assert(flags==DL_FLAG_AUTOREMOVE_CONSUMER && !bound_checks); link_calls++;
    if (unbind_during_link) bound=false;
    return link_failure ? NULL : &link;
}
static inline bool device_is_bound(struct device *d) { assert(d==&supplier.dev && link_calls==1); bound_checks++; return bound; }
static inline void put_device(struct device *d) { assert(d==&supplier.dev && device_refs==1); device_refs--; }
static inline bool msm_gpu_no_components(void) { return no_components; }
static inline int msm_gpu_probe(struct platform_device *p, int *ops) {
    (void)p; assert(ops==&a3xx_ops); standalone_calls++; return downstream_error;
}
static inline int component_add(struct device *d, int *ops) {
    (void)d; assert(ops==&a3xx_ops); component_calls++; return downstream_error;
}
C
awk '/^static int adreno_(link_llcc|probe)\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$source_file" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static void reset(void) {
    assert(!node_refs && !device_refs);
    node_present=device_present=bound=true; supplier_node.enabled=true;
    link_failure=unbind_during_link=no_components=false;
    node_gets=device_gets=link_calls=bound_checks=component_calls=standalone_calls=downstream_error=0;
}
static void references_released(void) { assert(!node_refs && !device_refs); }
int main(void) {
    struct device_node gpu_node={.gpu=true}; struct platform_device gpu={{&gpu_node}};
    reset(); device_present=false;
    assert(adreno_probe(&gpu)==-EPROBE_DEFER && !link_calls && !component_calls && !standalone_calls);
    references_released();
    reset(); bound=false;
    assert(adreno_probe(&gpu)==-EPROBE_DEFER && link_calls==1 && bound_checks==1 && !component_calls);
    references_released();
    reset(); unbind_during_link=true;
    assert(adreno_probe(&gpu)==-EPROBE_DEFER && !component_calls && !standalone_calls);
    references_released();
    reset(); link_failure=true;
    assert(adreno_probe(&gpu)==-ENOMEM && !component_calls && !bound_checks);
    references_released();
    reset(); assert(adreno_probe(&gpu)==0 && link_calls==1 && component_calls==1 && !standalone_calls);
    references_released();
    reset(); no_components=true;
    assert(adreno_probe(&gpu)==0 && link_calls==1 && !component_calls && standalone_calls==1);
    references_released();
    reset(); downstream_error=-EIO;
    assert(adreno_probe(&gpu)==-EIO && link_calls==1 && component_calls==1);
    references_released();
    reset(); node_present=false;
    assert(adreno_probe(&gpu)==0 && node_gets==1 && !device_gets && !link_calls && component_calls==1);
    references_released();
    reset(); supplier_node.enabled=false;
    assert(adreno_probe(&gpu)==0 && !device_gets && !link_calls && component_calls==1);
    references_released();
    reset(); gpu_node.gpu=false;
    assert(adreno_probe(&gpu)==0 && !node_gets && !link_calls && component_calls==1);
    references_released();
    reset(); gpu_node.imageon=true;
    assert(adreno_probe(&gpu)==0 && !node_gets && !component_calls && standalone_calls==1);
    references_released();
    gpu_node.imageon=false; gpu_node.gpu=true;
    reset(); bound=false; assert(adreno_probe(&gpu)==-EPROBE_DEFER); references_released();
    reset(); assert(adreno_probe(&gpu)==0 && component_calls==1); references_released();
    puts("Actual Adreno probe: optional legacy path, native LLCC deferral, post-link readiness, references, failures and both master paths passed");
}
C
"${CC:-gcc}" -std=gnu11 -O2 -Wall -Wextra -Werror ${LLCC_TEST_CFLAGS:-} "$work/check.c" -o "$work/check"
"$work/check"
