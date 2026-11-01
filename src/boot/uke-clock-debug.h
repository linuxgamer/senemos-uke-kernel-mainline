/* SPDX-License-Identifier: GPL-2.0-only */
/* The unbound OEM measurement client must not retain functional clock suppliers. */
static int UKE_INIT uke_clock_debug_retire(void *fdt)
{
	static const struct { const char *path; const char *name; } clocks[] = {
		{ "/soc/rsc@17a00000/drv@2/clock-controller", "xo_clk_src" },
		{ "/soc/clock-controller@ade0000", "camcc" },
		{ "/soc/clock-controller@af00000", "dispcc" },
		{ "/soc/clock-controller@100000", "gcc" },
		{ "/soc/clock-controller@3d90000", "gpucc" },
		{ "/soc/clock-controller@aaf0000", "videocc" },
	};
	const fdt32_t *value;
	const char *status;
	unsigned int phandle, i;
	int debug, length, other, node, depth = 0;

	if (fdt_node_check_compatible(fdt, 0, "xiaomi,uke") ||
	    fdt_node_check_compatible(fdt, 0, "qcom,sm7675"))
		return 0;
	debug = fdt_path_offset(fdt, "/soc/clock-controller@0");
	if (debug == -FDT_ERR_NOTFOUND)
		return 0;
	if (debug < 0)
		return debug;
	status = fdt_getprop(fdt, debug, "status", &length);
	if (status && length == sizeof("disabled") && !memcmp(status, "disabled", length))
		return 0;
	if (status && !((length == sizeof("okay") && !memcmp(status, "okay", length)) ||
			(length == sizeof("ok") && !memcmp(status, "ok", length))))
		return -FDT_ERR_BADVALUE;
	if (fdt_stringlist_count(fdt, debug, "compatible") != 1 ||
	    fdt_node_check_compatible(fdt, debug, "qcom,cliffs-debugcc") ||
	    fdt_getprop(fdt, debug, "reg", NULL) ||
	    !(phandle = fdt_get_phandle(fdt, debug)))
		return -FDT_ERR_BADVALUE;
	other = fdt_node_offset_by_compatible(fdt, -1, "qcom,cliffs-debugcc");
	if (other != debug ||
	    fdt_node_offset_by_compatible(fdt, debug, "qcom,cliffs-debugcc") != -FDT_ERR_NOTFOUND)
		return -FDT_ERR_BADVALUE;
	value = fdt_getprop(fdt, debug, "#clock-cells", &length);
	if (!value || length != sizeof(*value) || fdt32_to_cpu(*value) != 1 ||
	    fdt_stringlist_count(fdt, debug, "clock-names") != ARRAY_SIZE(clocks))
		return -FDT_ERR_BADVALUE;
	for (i = 0; i < ARRAY_SIZE(clocks); i++) {
		int provider = fdt_path_offset(fdt, clocks[i].path);
		unsigned int provider_phandle;

		if (provider < 0 || !(provider_phandle = fdt_get_phandle(fdt, provider)) ||
		    fdt_stringlist_search(fdt, debug, "clock-names", clocks[i].name) != (int)i)
			return -FDT_ERR_BADVALUE;
		value = fdt_getprop(fdt, provider, "#clock-cells", &length);
		if (!value || length != sizeof(*value) || fdt32_to_cpu(*value) != 1)
			return -FDT_ERR_BADVALUE;
		value = fdt_getprop(fdt, debug, "clocks", &length);
		if (!value || length != 2 * ARRAY_SIZE(clocks) * sizeof(*value) ||
		    fdt32_to_cpu(value[2 * i]) != provider_phandle ||
		    fdt32_to_cpu(value[2 * i + 1]) != 0)
			return -FDT_ERR_BADVALUE;
	}
	/* Conservatively reject every external cell matching the exported handle,
	 * including unfamiliar vendor reference properties. Do not guess consumers.
	 */
	for (node = fdt_next_node(fdt, -1, &depth); node >= 0 && depth >= 0;
	     node = fdt_next_node(fdt, node, &depth)) {
		int property;

		if (node == debug)
			continue;
		fdt_for_each_property_offset(property, fdt, node) {
			value = fdt_getprop_by_offset(fdt, property, NULL, &length);
			if (!value)
				return -FDT_ERR_BADSTRUCTURE;
			if (length % sizeof(*value))
				continue;
			for (i = 0; i < length / sizeof(*value); i++)
				if (fdt32_to_cpu(value[i]) == phandle)
					return -FDT_ERR_BADVALUE;
		}
	}
	if (node != -FDT_ERR_NOTFOUND && depth >= 0)
		return -FDT_ERR_BADSTRUCTURE;
	return fdt_setprop_string(fdt, debug, "status", "disabled");
}
