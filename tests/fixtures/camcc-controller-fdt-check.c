/* SPDX-License-Identifier: GPL-2.0-only */
/* Actual conversion, synthetic graph and private-data placeholder only. */
#include <assert.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <libfdt.h>
#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))
#define UKE_INIT
#include "uke-camcc-dt.h"
static _Alignas(8) char tree[65536], before[65536];
static const char camera_path[] = "/soc/clock-controller@ade0000";
static int camera(void) { int n = fdt_path_offset(tree, camera_path); assert(n >= 0); return n; }
static int addpath(const char *path)
{
	char component[128];
	int parent = 0;
	const char *part = path + 1;

	while (*part) {
		const char *end = strchr(part, '/');
		size_t bytes = end ? (size_t)(end - part) : strlen(part);
		assert(bytes && bytes < sizeof(component));
		memcpy(component, part, bytes); component[bytes] = 0;
		int node = fdt_subnode_offset(tree, parent, component);
		if (node == -FDT_ERR_NOTFOUND) node = fdt_add_subnode(tree, parent, component);
		assert(node >= 0); parent = node;
		if (!end) break;
		part = end + 1;
	}
	return parent;
}
static void reset(void)
{
	assert(!fdt_create_empty_tree(tree, sizeof(tree)));
	const char root[] = "xiaomi,uke\0qcom,sm7675";
	assert(!fdt_setprop(tree, 0, "compatible", root, sizeof(root)));
	int soc = addpath("/soc");
	assert(!fdt_setprop_u32(tree, soc, "#address-cells", 1));
	assert(!fdt_setprop_u32(tree, soc, "#size-cells", 1));
	for (unsigned int i = 0; i < 3; i++) {
		const char *names[] = {"/clocks/rpmh", "/clocks/sleep", "/clocks/gcc"};
		int n = addpath(names[i]);
		assert(!fdt_setprop_u32(tree, n, "phandle", 11 + i));
		assert(!fdt_setprop_u32(tree, n, "#clock-cells", i == 1 ? 0 : 1));
	}
	addpath(camera_path);
	assert(!fdt_setprop_string(tree, camera(), "compatible", "qcom,cliffs-camcc"));
	assert(!fdt_setprop_u32(tree, camera(), "phandle", 21));
	assert(!fdt_setprop_u32(tree, camera(), "#clock-cells", 1));
	assert(!fdt_setprop_u32(tree, camera(), "#reset-cells", 1));
	const fdt32_t reg[] = {cpu_to_fdt32(0xade0000), cpu_to_fdt32(0x20000)};
	assert(!fdt_setprop(tree, camera(), "reg", reg, sizeof(reg)));
	const fdt32_t clocks[] = {cpu_to_fdt32(11), 0, cpu_to_fdt32(11), cpu_to_fdt32(1), cpu_to_fdt32(12), cpu_to_fdt32(13), cpu_to_fdt32(10)};
	const char names[] = "bi_tcxo\0bi_tcxo_ao\0sleep_clk\0iface";
	assert(!fdt_setprop(tree, camera(), "clocks", clocks, sizeof(clocks)));
	assert(!fdt_setprop(tree, camera(), "clock-names", names, sizeof(names)));
	for (unsigned int i = 0; i < ARRAY_SIZE(uke_camcc_legacy); i++) {
		int n = addpath(uke_camcc_legacy[i].path);
		assert(!fdt_setprop_string(tree, n, "compatible", uke_camcc_legacy[i].compatible));
	}
	const fdt32_t consumer[] = {cpu_to_fdt32(21), cpu_to_fdt32(71)};
	int rsc = fdt_path_offset(tree, "/soc/rsc@add4000");
	assert(!fdt_setprop(tree, rsc, "clocks", consumer, sizeof(consumer)));
	int other = addpath("/unrelated/rtc");
	assert(!fdt_setprop_string(tree, other, "status", "okay"));
	assert(!fdt_setprop_string(tree, other, "synthetic-private-placeholder", "unchanged"));
}
static void refused(void)
{
	memcpy(before, tree, sizeof(tree));
	assert(uke_camcc_controller_graph(tree) < 0);
	assert(!memcmp(before, tree, sizeof(tree)));
}
int main(void)
{
	reset(); assert(!uke_camcc_controller_graph(tree));
	assert(!fdt_node_check_compatible(tree, camera(), "qcom,sm7675-camcc"));
	int size;
	const fdt32_t *clocks = fdt_getprop(tree, camera(), "clocks", &size);
	const unsigned int expected[] = {13, 10, 11, 0, 11, 1, 12};
	assert(clocks && size == 28);
	for (unsigned int i = 0; i < ARRAY_SIZE(expected); i++) assert(fdt32_to_cpu(clocks[i]) == expected[i]);
	const fdt32_t *reg = fdt_getprop(tree, camera(), "reg", &size);
	assert(reg && size == 16 && fdt32_to_cpu(reg[2]) == 0xadd7000 && fdt32_to_cpu(reg[3]) == 0x2000);
	for (unsigned int i = 0; i < ARRAY_SIZE(uke_camcc_legacy); i++) {
		int n = fdt_path_offset(tree, uke_camcc_legacy[i].path);
		const char *status = fdt_getprop(tree, n, "status", &size);
		assert(status && size == 9 && !strcmp(status, "disabled"));
	}
	int other = fdt_path_offset(tree, "/unrelated/rtc");
	assert(!strcmp(fdt_getprop(tree, other, "status", NULL), "okay"));
	assert(!strcmp(fdt_getprop(tree, other, "synthetic-private-placeholder", NULL), "unchanged"));
	memcpy(before, tree, sizeof(tree)); assert(!uke_camcc_controller_graph(tree)); assert(!memcmp(before, tree, sizeof(tree)));
	reset(); assert(!fdt_setprop_string(tree, 0, "compatible", "xiaomi,other")); refused();
	reset(); assert(!fdt_setprop_u32(tree, camera(), "reg", 0xade0004)); refused();
	reset(); assert(!fdt_setprop_u32(tree, camera(), "protected-clocks", 0)); refused();
	reset(); assert(!fdt_setprop_u32(tree, camera(), "power-domains", 11)); refused();
	reset(); assert(!fdt_setprop_u32(tree, camera(), "#clock-cells", 2)); refused();
	reset(); assert(!fdt_setprop_u32(tree, camera(), "#reset-cells", 2)); refused();
	reset(); assert(!fdt_setprop_string(tree, camera(), "clock-names", "iface")); refused();
	reset(); assert(!fdt_setprop_string(tree, fdt_path_offset(tree, uke_camcc_legacy[0].path), "compatible", "qcom,other")); refused();
	reset(); assert(!fdt_del_node(tree, fdt_path_offset(tree, uke_camcc_legacy[0].path))); refused();
	reset(); other = addpath("/unrelated/clock-consumer");
	const fdt32_t unknown[] = {cpu_to_fdt32(21), cpu_to_fdt32(71)};
	assert(!fdt_setprop(tree, other, "clocks", unknown, sizeof(unknown))); refused();
	reset(); other = addpath("/unrelated/broken-clock-tuple");
	assert(!fdt_setprop_u32(tree, other, "clocks", 11)); refused();
	puts("Actual CAMCC FDT: exact controller/clock permutation, named CRM resource, legacy consumer containment, unrelated data and idempotence pass; malformed/foreign/unknown graphs refuse before mutation; synthetic FDT only");
	return 0;
}
