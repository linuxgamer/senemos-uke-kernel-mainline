/* SPDX-License-Identifier: GPL-2.0-only */
/* Exact Uke DDR monitor; CPU/LLCC needs its separate secondary L3 vote. */
#ifdef __KERNEL__
#include <dt-bindings/interconnect/qcom,icc.h>
#define UKE_BWMON_ACTIVE_ONLY QCOM_ICC_TAG_ACTIVE_ONLY
#else
/* Same native binding value: AMC and WAKE buckets, excluding SLEEP. */
#define UKE_BWMON_ACTIVE_ONLY 3U
#endif

static int UKE_INIT uke_bwmon_properties(const void *fdt, int node,
				      const char *const *allowed, unsigned int count)
{
	const char *name;
	unsigned int i;
	int prop;

	fdt_for_each_property_offset(prop, fdt, node) {
		if (!fdt_getprop_by_offset(fdt, prop, &name, NULL))
			return -FDT_ERR_BADVALUE;
		for (i = 0; i < count; i++)
			if (!strcmp(name, allowed[i]))
				break;
		if (i == count)
			return -FDT_ERR_BADVALUE;
	}
	return prop == -FDT_ERR_NOTFOUND ? 0 : prop;
}

static int UKE_INIT uke_bwmon_cells(const void *fdt, int node, const char *name,
				 const unsigned int *expected, unsigned int count)
{
	int bytes;
	unsigned int i;
	const fdt32_t *cells = (const fdt32_t *)fdt_getprop(fdt, node, name, &bytes);

	if (!cells || bytes != (int)(count * sizeof(*cells)))
		return -FDT_ERR_BADVALUE;
	for (i = 0; i < count; i++)
		if (fdt32_to_cpu(cells[i]) != expected[i])
			return -FDT_ERR_BADVALUE;
	return 0;
}

/* Add a zero tag to existing MC requests before exposing active-only votes. */
static int UKE_INIT uke_bwmon_mc_tags(void *fdt, unsigned int mc)
{
	fdt32_t output[256];
	int node = -1, bytes, ret, provider;
	const fdt32_t *input, *cells;
	unsigned int pos, used, args, old_args, i, handle;

	provider = fdt_node_offset_by_phandle(fdt, mc);
	cells = (const fdt32_t *)fdt_getprop(fdt, provider, "#interconnect-cells", &bytes);
	if (!cells || bytes != (int)sizeof(*cells))
		return -FDT_ERR_BADVALUE;
	old_args = fdt32_to_cpu(*cells);
	if (old_args != 1 && old_args != 2)
		return -FDT_ERR_BADVALUE;
	while ((node = fdt_next_node(fdt, node, NULL)) >= 0) {
		bool changed = false;

		input = (const fdt32_t *)fdt_getprop(fdt, node, "interconnects", &bytes);
		if (!input)
			continue;
		if (bytes <= 0 || bytes % sizeof(*input))
			return -FDT_ERR_BADVALUE;
		used = 0;
		for (pos = 0; pos < bytes / sizeof(*input);) {
			handle = fdt32_to_cpu(input[pos]);
			provider = fdt_node_offset_by_phandle(fdt, handle);
			cells = (const fdt32_t *)fdt_getprop(fdt, provider, "#interconnect-cells", &ret);
			if (!cells || ret != (int)sizeof(*cells))
				return -FDT_ERR_BADVALUE;
			args = fdt32_to_cpu(*cells);
			if (args > 16 || args + 1 > bytes / sizeof(*input) - pos ||
			    used + args + 2 > ARRAY_SIZE(output))
				return -FDT_ERR_BADVALUE;
			if (handle == mc && args == 2 && (fdt32_to_cpu(input[pos + 2]) & ~7U))
				return -FDT_ERR_BADVALUE;
			for (i = 0; i <= args; i++)
				output[used++] = input[pos++];
			if (handle == mc && old_args == 1) {
				output[used++] = cpu_to_fdt32(0);
				changed = true;
			}
		}
		if (changed) {
			ret = fdt_setprop(fdt, node, "interconnects", output, used * sizeof(*output));
			if (ret)
				return ret;
		}
	}
	if (node != -FDT_ERR_NOTFOUND)
		return node;
	provider = fdt_node_offset_by_phandle(fdt, mc);
	return fdt_setprop_u32(fdt, provider, "#interconnect-cells", 2);
}

static int UKE_INIT uke_bwmon_apply(void *fdt)
{
	static const char path[] = "/soc/qcom,bwmon-ddr@24091000";
	static const char compatible[] = "qcom,sm7675-llcc-bwmon\0qcom,sc7280-llcc-bwmon";
	static const unsigned int frequencies[] = {
		547000, 768000, 1555000, 1708000, 2092000, 2736000, 3187000, 3686000, 4224000
	};
	static const char *const obsolete[] = {
		"reg-names", "qcom,hw-timer-hz", "qcom,count-unit", "qcom,target-dev"
	};
	static const char *const monitor_properties[] = {
		"compatible", "reg", "interrupts", "phandle", "linux,phandle", "status",
		"reg-names", "qcom,hw-timer-hz", "qcom,count-unit", "qcom,target-dev",
		"interconnects", "operating-points-v2"
	};
	static const char *const table_properties[] = { "compatible", "phandle", "linux,phandle" };
	static const char *const peak_properties[] = { "opp-peak-kBps" };
	const unsigned int reg[] = { 0x24091000, 0x1000 }, irq[] = { 0, 81, 4 };
	const unsigned int timer[] = { 19200000 }, unit[] = { 65536 }, width[] = { 4 };
	const unsigned int type[] = { 0 };
	const fdt32_t *cells;
	const char *text;
	unsigned int mc, target, table, opp_handle, i, count;
	unsigned int icc[6];
	fdt32_t wire_icc[6];
	int node, provider, dev, freq, opps, child, bytes, ret;
	bool native;
	char name[32];

	if (fdt_node_check_compatible(fdt, 0, "xiaomi,uke") ||
	    fdt_node_check_compatible(fdt, 0, "qcom,sm7675"))
		return -FDT_ERR_BADVALUE;
	node = fdt_path_offset(fdt, path);
	if (node == -FDT_ERR_NOTFOUND)
		return 0;
	provider = fdt_path_offset(fdt, "/soc/interconnect@1");
	dev = fdt_path_offset(fdt, "/soc/qcom,dcvs/ddr");
	freq = fdt_path_offset(fdt, "/soc/ddr-freq-table");
	if (node < 0 || provider < 0 || dev < 0 || freq < 0 ||
	    uke_bwmon_properties(fdt, node, monitor_properties, ARRAY_SIZE(monitor_properties)) ||
	    fdt_node_check_compatible(fdt, provider, "qcom,cliffs-mc_virt") ||
	    fdt_node_check_compatible(fdt, dev, "qcom,dcvs-hw") ||
	    fdt_address_cells(fdt, fdt_parent_offset(fdt, node)) != 1 ||
	    fdt_size_cells(fdt, fdt_parent_offset(fdt, node)) != 1 ||
	    uke_bwmon_cells(fdt, node, "reg", reg, ARRAY_SIZE(reg)) ||
	    uke_bwmon_cells(fdt, node, "interrupts", irq, ARRAY_SIZE(irq)) ||
	    uke_bwmon_cells(fdt, dev, "qcom,dcvs-hw-type", type, 1) ||
	    uke_bwmon_cells(fdt, dev, "qcom,bus-width", width, 1) ||
	    uke_bwmon_cells(fdt, freq, "qcom,freq-tbl", frequencies, ARRAY_SIZE(frequencies)))
		return -FDT_ERR_BADVALUE;
	mc = fdt_get_phandle(fdt, provider);
	target = fdt_get_phandle(fdt, dev);
	table = fdt_get_phandle(fdt, freq);
	if (!mc || !target || !table || uke_bwmon_cells(fdt, dev, "qcom,freq-tbl", &table, 1))
		return -FDT_ERR_BADVALUE;
	cells = (const fdt32_t *)fdt_getprop(fdt, provider, "#interconnect-cells", &bytes);
	if (!cells || bytes != (int)sizeof(*cells) ||
	    (fdt32_to_cpu(*cells) != 1 && fdt32_to_cpu(*cells) != 2))
		return -FDT_ERR_BADVALUE;
	count = fdt32_to_cpu(*cells);
	icc[0] = mc; icc[1] = 3; icc[2] = count == 1 ? mc : 0;
	icc[count + 1] = mc; icc[count + 2] = 512; icc[count + 3] = 0;
	child = fdt_subnode_offset(fdt, dev, "sp");
	if (child < 0 || uke_bwmon_cells(fdt, child, "interconnects", icc, (count + 1) * 2))
		return -FDT_ERR_BADVALUE;
	native = !fdt_node_check_compatible(fdt, node, "qcom,sm7675-llcc-bwmon");
	text = (const char *)fdt_getprop(fdt, node, "compatible", &bytes);
	if (!text || (native ? (bytes != (int)sizeof(compatible) || memcmp(text, compatible, sizeof(compatible))) :
			(bytes != (int)sizeof("qcom,bwmon5") || memcmp(text, "qcom,bwmon5", sizeof("qcom,bwmon5")))))
		return -FDT_ERR_BADVALUE;
	if (!native) {
		if (fdt_node_check_compatible(fdt, node, "qcom,bwmon5") ||
		    uke_bwmon_cells(fdt, node, "qcom,hw-timer-hz", timer, 1) ||
		    uke_bwmon_cells(fdt, node, "qcom,count-unit", unit, 1) ||
		    uke_bwmon_cells(fdt, node, "qcom,target-dev", &target, 1) ||
		    fdt_getprop(fdt, node, "interconnects", NULL) ||
		    fdt_getprop(fdt, node, "operating-points-v2", NULL) ||
		    fdt_subnode_offset(fdt, node, "opp-table") != -FDT_ERR_NOTFOUND)
			return -FDT_ERR_BADVALUE;
	} else {
		icc[0] = mc; icc[1] = 3; icc[2] = UKE_BWMON_ACTIVE_ONLY;
		icc[3] = mc; icc[4] = 512; icc[5] = UKE_BWMON_ACTIVE_ONLY;
		if (count != 2 || uke_bwmon_cells(fdt, node, "interconnects", icc, 6))
			return -FDT_ERR_BADVALUE;
		opps = fdt_subnode_offset(fdt, node, "opp-table");
		opp_handle = fdt_get_phandle(fdt, opps);
		if (opps < 0 || !opp_handle ||
		    uke_bwmon_properties(fdt, opps, table_properties, ARRAY_SIZE(table_properties)) ||
		    fdt_node_check_compatible(fdt, opps, "operating-points-v2") ||
		    uke_bwmon_cells(fdt, node, "operating-points-v2", &opp_handle, 1))
			return -FDT_ERR_BADVALUE;
		count = 0;
		fdt_for_each_subnode(child, fdt, opps) { count++; }
		if (count != ARRAY_SIZE(frequencies))
			return -FDT_ERR_BADVALUE;
		for (i = 0; i < ARRAY_SIZE(frequencies); i++) {
			unsigned int peak = frequencies[i] * 4;

			snprintf(name, sizeof(name), "opp-%u", frequencies[i]);
			child = fdt_subnode_offset(fdt, opps, name);
			if (child < 0 || uke_bwmon_cells(fdt, child, "opp-peak-kBps", &peak, 1) ||
			    uke_bwmon_properties(fdt, child, peak_properties, ARRAY_SIZE(peak_properties)))
				return -FDT_ERR_BADVALUE;
		}
		for (i = 0; i < ARRAY_SIZE(obsolete); i++)
			if (fdt_getprop(fdt, node, obsolete[i], NULL))
				return -FDT_ERR_BADVALUE;
	}
	text = (const char *)fdt_getprop(fdt, node, "status", &bytes);
	if (text && !((bytes == 9 && !memcmp(text, "disabled", 9)) ||
		      (bytes == 5 && !memcmp(text, "okay", 5)) || (bytes == 3 && !memcmp(text, "ok", 3))))
		return -FDT_ERR_BADVALUE;
	ret = uke_bwmon_mc_tags(fdt, mc);
	if (ret || native)
		return ret;
	node = fdt_path_offset(fdt, path);
	ret = fdt_setprop(fdt, node, "compatible", compatible, sizeof(compatible));
	if (ret)
		return ret;
	for (i = 0; i < ARRAY_SIZE(obsolete); i++) {
		ret = fdt_delprop(fdt, node, obsolete[i]);
		if (ret && ret != -FDT_ERR_NOTFOUND)
			return ret;
	}
	icc[0] = mc; icc[1] = 3; icc[2] = UKE_BWMON_ACTIVE_ONLY;
	icc[3] = mc; icc[4] = 512; icc[5] = UKE_BWMON_ACTIVE_ONLY;
	for (i = 0; i < ARRAY_SIZE(icc); i++) wire_icc[i] = cpu_to_fdt32(icc[i]);
	ret = fdt_setprop(fdt, node, "interconnects", wire_icc, sizeof(wire_icc));
	if (ret)
		return ret;
	opps = fdt_add_subnode(fdt, node, "opp-table");
	if (opps < 0)
		return opps;
	ret = fdt_setprop_string(fdt, opps, "compatible", "operating-points-v2");
	if (ret)
		return ret;
	ret = fdt_generate_phandle(fdt, &opp_handle);
	if (ret)
		return ret;
	ret = fdt_setprop_u32(fdt, opps, "phandle", opp_handle);
	if (ret)
		return ret;
	node = fdt_path_offset(fdt, path);
	ret = fdt_setprop_u32(fdt, node, "operating-points-v2", opp_handle);
	if (ret)
		return ret;
	for (i = 0; i < ARRAY_SIZE(frequencies); i++) {
		node = fdt_path_offset(fdt, path);
		opps = fdt_subnode_offset(fdt, node, "opp-table");
		snprintf(name, sizeof(name), "opp-%u", frequencies[i]);
		child = fdt_add_subnode(fdt, opps, name);
		if (child < 0)
			return child;
		ret = fdt_setprop_u32(fdt, child, "opp-peak-kBps", frequencies[i] * 4);
		if (ret)
			return ret;
	}
	return 0;
}
