/* SPDX-License-Identifier: GPL-2.0-only */
/* Cliffs7 graph: MiCode DT 94c84aeb9e517dbde546fc732033c184094c8e57. */
#ifndef UKE_LLCC_H
#define UKE_LLCC_H

#define UKE_LLCC_PATH "/soc/cache-controller@25000000"

static int UKE_INIT uke_llcc_admit(const void *fdt)
{
	static const char compatible[] = "qcom,cliffs7-llcc\0qcom,llcc-v50";
	static const char names[] = "llcc_base\0llcc_broadcast_base";
	static const unsigned int expected[] = {
		0x25000000, 0x800000, 0x25800000, 0x200000,
	};
	static const unsigned int irq[] = { 0, 266, 4 };
	const fdt32_t *cells;
	const char *value;
	int node = fdt_path_offset(fdt, UKE_LLCC_PATH);
	int soc = fdt_path_offset(fdt, "/soc"), size, child;
	unsigned int i;

	if (node < 0 || soc < 0 || fdt_address_cells(fdt, soc) != 1 ||
	    fdt_size_cells(fdt, soc) != 1)
		return -FDT_ERR_BADVALUE;
	cells = fdt_getprop(fdt, soc, "#size-cells", &size);
	if (!cells || size != sizeof(*cells) || fdt32_to_cpu(*cells) != 1)
		return -FDT_ERR_BADVALUE;
	value = fdt_getprop(fdt, node, "compatible", &size);
	if (!value || size != sizeof(compatible) || memcmp(value, compatible, size))
		return -FDT_ERR_BADVALUE;
	value = fdt_getprop(fdt, node, "reg-names", &size);
	if (!value || size != sizeof(names) || memcmp(value, names, size))
		return -FDT_ERR_BADVALUE;
	cells = fdt_getprop(fdt, node, "reg", &size);
	if (!cells || size != sizeof(expected))
		return -FDT_ERR_BADVALUE;
	for (i = 0; i < ARRAY_SIZE(expected); i++)
		if (fdt32_to_cpu(cells[i]) != expected[i])
			return -FDT_ERR_BADVALUE;
	cells = fdt_getprop(fdt, node, "interrupts", &size);
	if (!cells || size != sizeof(irq))
		return -FDT_ERR_BADVALUE;
	for (i = 0; i < ARRAY_SIZE(irq); i++)
		if (fdt32_to_cpu(cells[i]) != irq[i])
			return -FDT_ERR_BADVALUE;
	value = fdt_getprop(fdt, node, "status", &size);
	if (value && !((size == 5 && !memcmp(value, "okay", 5)) ||
		       (size == 3 && !memcmp(value, "ok", 3))))
		return -FDT_ERR_BADVALUE;
	if (!value && size != -FDT_ERR_NOTFOUND)
		return -FDT_ERR_BADVALUE;
	fdt_for_each_subnode(child, fdt, node)
		if (strcmp(fdt_get_name(fdt, child, NULL), "llcc-perfmon"))
			return -FDT_ERR_BADVALUE;
	return child == -FDT_ERR_NOTFOUND ? 0 : child;
}

/* The caller owns a validated scratch DT and must discard it on any error. */
static int UKE_INIT uke_llcc_apply(void *fdt)
{
	static const unsigned int regions[] = {
		0x25000000, 0x200000, 0x25200000, 0x200000, 0x25400000, 0x200000,
		0x25600000, 0x200000, 0x25800000, 0x200000,
	};
	static const char names[] = "llcc0_base\0llcc1_base\0llcc2_base\0"
		"llcc3_base\0llcc_broadcast_base";
	static const char * const remove[] = { "label", "cap-based-alloc-and-pwr-collapse" };
	fdt32_t reg[ARRAY_SIZE(regions)];
	int node, child, ret;
	unsigned int i;

	ret = uke_llcc_admit(fdt);
	if (ret)
		return ret;
	node = fdt_path_offset(fdt, UKE_LLCC_PATH);
	for (i = 0; i < ARRAY_SIZE(regions); i++)
		reg[i] = cpu_to_fdt32(regions[i]);
	ret = fdt_setprop(fdt, node, "reg", reg, sizeof(reg));
	if (ret)
		return ret;
	ret = fdt_setprop(fdt, node, "reg-names", names, sizeof(names));
	if (ret)
		return ret;
	ret = fdt_setprop_string(fdt, node, "compatible", "qcom,sm7675-llcc");
	if (ret)
		return ret;
	ret = fdt_setprop_string(fdt, node, "status", "okay");
	if (ret)
		return ret;
	for (i = 0; i < ARRAY_SIZE(remove); i++) {
		ret = fdt_delprop(fdt, node, remove[i]);
		if (ret && ret != -FDT_ERR_NOTFOUND)
			return ret;
	}
	child = fdt_subnode_offset(fdt, node, "llcc-perfmon");
	if (child >= 0)
		return fdt_del_node(fdt, child);
	return child == -FDT_ERR_NOTFOUND ? 0 : child;
}

#endif
