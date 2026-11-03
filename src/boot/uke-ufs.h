/* SPDX-License-Identifier: GPL-2.0-only */
/* Exact Cliffs resource/allocator admission before enabling native UFS ICE. */
static int UKE_INIT uke_ufs_admit(const void *fdt)
{
	static const unsigned int ranges[] = {
		0x1d84000, 0x3000, 0x1d88000, 0x8000, 0x1d90000, 0x9000,
		0x1da5000, 0x2000, 0x1da4000, 0x10,
	};
	static const char names[] = "ufs_mem\0ufs_ice\0ufs_ice_hwkm\0mcq_sqd\0mcq_vs";
	static const unsigned int cores[] = { 28, 28, 15, 13 };
	const fdt32_t *value;
	const char *strings;
	int node = fdt_path_offset(fdt, "/soc/ufshc@1d84000"), bytes, config, child;
	unsigned int i;

	if (node < 0 || fdt_node_check_compatible(fdt, node, "qcom,ufshc"))
		return -FDT_ERR_BADVALUE;
	value = (const fdt32_t *)fdt_getprop(fdt, node, "reg", &bytes);
	if (!value || bytes != (int)sizeof(ranges))
		return -FDT_ERR_BADVALUE;
	for (i = 0; i < ARRAY_SIZE(ranges); i++)
		if (fdt32_to_cpu(value[i]) != ranges[i])
			return -FDT_ERR_BADVALUE;
	strings = (const char *)fdt_getprop(fdt, node, "reg-names", &bytes);
	if (!strings || bytes != (int)sizeof(names) || memcmp(strings, names, sizeof(names)))
		return -FDT_ERR_BADVALUE;
	value = (const fdt32_t *)fdt_getprop(fdt, node, "shared-ice-cfg", &bytes);
	if (!value || bytes != (int)sizeof(*value))
		return -FDT_ERR_BADVALUE;
	config = fdt_node_offset_by_phandle(fdt, fdt32_to_cpu(*value));
	if (config < 0)
		return -FDT_ERR_BADVALUE;
	/* Native allocator type 2 matches OEM alg3 only, not arbitrary shared-ICE policy. */
	child = fdt_subnode_offset(fdt, config, "alg3");
	strings = child < 0 ? NULL : (const char *)fdt_getprop(fdt, child, "status", &bytes);
	if (!strings || !((bytes == 3 && !memcmp(strings, "ok", 3)) ||
			 (bytes == 5 && !memcmp(strings, "okay", 5))))
		return -FDT_ERR_BADVALUE;
	value = (const fdt32_t *)fdt_getprop(fdt, child, "num-core", &bytes);
	if (!value || bytes != (int)sizeof(cores))
		return -FDT_ERR_BADVALUE;
	for (i = 0; i < ARRAY_SIZE(cores); i++)
		if (fdt32_to_cpu(value[i]) != cores[i])
			return -FDT_ERR_BADVALUE;
	fdt_for_each_subnode(child, fdt, config) {
		if (child == fdt_subnode_offset(fdt, config, "alg3"))
			continue;
		strings = (const char *)fdt_getprop(fdt, child, "status", &bytes);
		if (!strings || bytes != 9 || memcmp(strings, "disabled", 9))
			return -FDT_ERR_BADVALUE;
	}
	return 0;
}
