/* SPDX-License-Identifier: GPL-2.0-only */
/* Exact OEM CPU/LLCC monitor and paired shared-L3 vote, after all overlays. */
static int UKE_INIT uke_cpu_bwmon_status(const void *fdt, int node)
{
	int bytes;
	const char *status = (const char *)fdt_getprop(fdt, node, "status", &bytes);

	if (!status || (bytes == 5 && !memcmp(status, "okay", 5)) ||
	    (bytes == 3 && !memcmp(status, "ok", 3)))
		return 0;
	return bytes == 9 && !memcmp(status, "disabled", 9) ? 1 : -FDT_ERR_BADVALUE;
}

static int UKE_INIT uke_cpu_bwmon_apply(void *fdt)
{
	static const char path[] = "/soc/qcom,bwmon-llcc@240B7300";
	static const char l3_path[] = "/soc/interconnect@17d90000";
	static const char mon_compat[] = "qcom,sm7675-cpu-bwmon\0qcom,sdm845-bwmon";
	static const char l3_compat[] = "qcom,sm7675-epss-l3\0qcom,epss-l3";
	static const unsigned int frequencies[] = { 300000, 466500, 600000, 806000, 933000, 1066000 };
	static const unsigned int mapping[] = {
		300000, 364800, 466500, 518400, 600000, 614400,
		806000, 806400, 933000, 902400, 1066000, 998400
	};
	static const char *const monitor_props[] = {
		"compatible", "reg", "reg-names", "interrupts", "phandle", "linux,phandle", "status",
		"qcom,mport", "qcom,hw-timer-hz", "qcom,count-unit", "qcom,target-dev", "qcom,second-vote",
		"interconnects", "operating-points-v2"
	};
	static const char *const obsolete[] = {
		"reg-names", "qcom,mport", "qcom,hw-timer-hz", "qcom,count-unit", "qcom,target-dev", "qcom,second-vote"
	};
	static const char *const l3_props[] = {
		"compatible", "reg", "clocks", "clock-names", "#interconnect-cells", "phandle", "linux,phandle"
	};
	static const char *const table_props[] = { "compatible", "phandle", "linux,phandle" };
	static const char *const peak_props[] = { "opp-peak-kBps" };
	const unsigned int old_reg[] = { 0x240b7400, 0x300, 0x240b7300, 0x200 };
	const unsigned int new_reg[] = { 0x240b7400, 0x300 }, irq[] = { 0, 581, 4 };
	const unsigned int l3_reg[] = { 0x17d90000, 0x4000, 0x17d90100, 0xa0 };
	const unsigned int native_l3_reg[] = { 0x17d90000, 0x1000 };
	const unsigned int cpu_reg[] = { 0x17d91000, 0x1000, 0x17d92000, 0x1000, 0x17d93000, 0x1000 };
	const unsigned int timer[] = { 19200000 }, unit[] = { 65536 }, zero[] = { 0 }, one[] = { 1 };
	const unsigned int llcc_type[] = { 1 }, llcc_width[] = { 16 }, l3_type[] = { 2 }, l3_width[] = { 32 }, offset[] = { 0x90 };
	unsigned int gem, target, freq_handle, second, l3_target, l3_handle, opp_handle, i, count, clock_handles[4], icc[10];
	fdt32_t wire[10];
	int node, provider, llcc, freq, vote, l3, sp, cpu, xo, gcc, bytes, ret, native_l3, opps, child;
	const char *text;
	bool native;
	char name[32];

	if (fdt_node_check_compatible(fdt, 0, "xiaomi,uke") ||
	    fdt_node_check_compatible(fdt, 0, "qcom,sm7675"))
		return -FDT_ERR_BADVALUE;
	node = fdt_path_offset(fdt, path);
	if (node == -FDT_ERR_NOTFOUND)
		return 0;
	if (node < 0 || uke_bwmon_properties(fdt, node, monitor_props, ARRAY_SIZE(monitor_props)))
		return -FDT_ERR_BADVALUE;
	ret = uke_cpu_bwmon_status(fdt, node);
	if (ret)
		return ret == 1 ? 0 : ret;
	provider = fdt_path_offset(fdt, "/soc/interconnect@24100000");
	llcc = fdt_path_offset(fdt, "/soc/qcom,dcvs/llcc");
	freq = fdt_path_offset(fdt, "/soc/llcc-freq-table");
	vote = fdt_path_offset(fdt, "/soc/qcom,llcc-l3-vote");
	l3 = fdt_path_offset(fdt, "/soc/qcom,dcvs/l3");
	cpu = fdt_path_offset(fdt, "/soc/qcom,cpufreq-hw");
	xo = fdt_path_offset(fdt, "/soc/rsc@17a00000/drv@2/clock-controller");
	gcc = fdt_path_offset(fdt, "/soc/clock-controller@100000");
	if (provider < 0 || llcc < 0 || freq < 0 || vote < 0 || l3 < 0 || cpu < 0 || xo < 0 || gcc < 0 ||
	    fdt_node_check_compatible(fdt, provider, "qcom,cliffs-gem_noc") ||
	    fdt_node_check_compatible(fdt, llcc, "qcom,dcvs-hw") ||
	    fdt_node_check_compatible(fdt, l3, "qcom,dcvs-hw") ||
	    fdt_node_check_compatible(fdt, cpu, "qcom,cpufreq-epss") ||
	    fdt_node_check_compatible(fdt, xo, "qcom,cliffs-rpmh-clk") ||
	    fdt_node_check_compatible(fdt, gcc, "qcom,cliffs-gcc") ||
	    fdt_address_cells(fdt, fdt_parent_offset(fdt, node)) != 1 ||
	    fdt_size_cells(fdt, fdt_parent_offset(fdt, node)) != 1 ||
	    uke_bwmon_cells(fdt, node, "interrupts", irq, 3) ||
	    uke_bwmon_cells(fdt, llcc, "qcom,dcvs-hw-type", llcc_type, 1) ||
	    uke_bwmon_cells(fdt, llcc, "qcom,bus-width", llcc_width, 1) ||
	    uke_bwmon_cells(fdt, freq, "qcom,freq-tbl", frequencies, ARRAY_SIZE(frequencies)) ||
	    uke_bwmon_cells(fdt, vote, "qcom,secondary-map", mapping, ARRAY_SIZE(mapping)) ||
	    uke_bwmon_cells(fdt, l3, "qcom,dcvs-hw-type", l3_type, 1) ||
	    uke_bwmon_cells(fdt, l3, "qcom,bus-width", l3_width, 1) ||
	    uke_bwmon_cells(fdt, l3, "reg", l3_reg, 4) ||
	    uke_bwmon_cells(fdt, cpu, "reg", cpu_reg, 6) ||
	    uke_bwmon_cells(fdt, xo, "#clock-cells", one, 1) ||
	    uke_bwmon_cells(fdt, gcc, "#clock-cells", one, 1) ||
	    uke_cpu_bwmon_status(fdt, provider) || uke_cpu_bwmon_status(fdt, xo) ||
	    uke_cpu_bwmon_status(fdt, gcc) || uke_cpu_bwmon_status(fdt, l3))
		return -FDT_ERR_BADVALUE;
	sp = fdt_subnode_offset(fdt, l3, "sp");
	if (sp < 0 || uke_bwmon_cells(fdt, sp, "qcom,dcvs-path-type", zero, 1) ||
	    uke_bwmon_cells(fdt, sp, "qcom,shared-offset", offset, 1))
		return -FDT_ERR_BADVALUE;
	gem = fdt_get_phandle(fdt, provider); target = fdt_get_phandle(fdt, llcc);
	freq_handle = fdt_get_phandle(fdt, freq); second = fdt_get_phandle(fdt, vote); l3_target = fdt_get_phandle(fdt, l3);
	clock_handles[0] = fdt_get_phandle(fdt, xo); clock_handles[1] = 0;
	clock_handles[2] = fdt_get_phandle(fdt, gcc); clock_handles[3] = 0;
	if (!gem || !target || !freq_handle || !second || !l3_target || !clock_handles[0] || !clock_handles[2] ||
	    uke_bwmon_cells(fdt, llcc, "qcom,freq-tbl", &freq_handle, 1) ||
	    uke_bwmon_cells(fdt, vote, "qcom,target-dev", &l3_target, 1) ||
	    uke_bwmon_cells(fdt, cpu, "clocks", clock_handles, 4))
		return -FDT_ERR_BADVALUE;
	text = (const char *)fdt_getprop(fdt, cpu, "clock-names", &bytes);
	if (!text || bytes != (int)sizeof("xo\0alternate") || memcmp(text, "xo\0alternate", bytes))
		return -FDT_ERR_BADVALUE;
	text = (const char *)fdt_getprop(fdt, provider, "#interconnect-cells", &bytes);
	if (!text || bytes != 4)
		return -FDT_ERR_BADVALUE;
	memcpy(wire, text, 4); count = fdt32_to_cpu(wire[0]);
	if (count != 1 && count != 2)
		return -FDT_ERR_BADVALUE;
	icc[0] = gem; icc[1] = 2; icc[2] = count == 1 ? gem : 0;
	icc[count + 1] = gem; icc[count + 2] = 555; icc[count + 3] = 0;
	sp = fdt_subnode_offset(fdt, llcc, "sp");
	if (sp < 0 || uke_bwmon_cells(fdt, sp, "interconnects", icc, (count + 1) * 2))
		return -FDT_ERR_BADVALUE;
	native = !fdt_node_check_compatible(fdt, node, "qcom,sm7675-cpu-bwmon");
	text = (const char *)fdt_getprop(fdt, node, "compatible", &bytes);
	if (!text || (native ? (bytes != (int)sizeof(mon_compat) || memcmp(text, mon_compat, bytes)) :
	    (bytes != (int)sizeof("qcom,bwmon4") || memcmp(text, "qcom,bwmon4", bytes))))
		return -FDT_ERR_BADVALUE;
	if (uke_bwmon_cells(fdt, node, "reg", native ? new_reg : old_reg, native ? 2 : 4))
		return -FDT_ERR_BADVALUE;
	native_l3 = fdt_path_offset(fdt, l3_path);
	if (!native) {
		if (uke_bwmon_cells(fdt, node, "qcom,mport", zero, 1) ||
		    uke_bwmon_cells(fdt, node, "qcom,hw-timer-hz", timer, 1) ||
		    uke_bwmon_cells(fdt, node, "qcom,count-unit", unit, 1) ||
		    uke_bwmon_cells(fdt, node, "qcom,target-dev", &target, 1) ||
		    uke_bwmon_cells(fdt, node, "qcom,second-vote", &second, 1) ||
		    fdt_getprop(fdt, node, "interconnects", NULL) || fdt_getprop(fdt, node, "operating-points-v2", NULL) ||
		    fdt_subnode_offset(fdt, node, "opp-table") != -FDT_ERR_NOTFOUND || native_l3 != -FDT_ERR_NOTFOUND)
			return -FDT_ERR_BADVALUE;
	} else {
		l3_handle = fdt_get_phandle(fdt, native_l3);
		text = (const char *)fdt_getprop(fdt, native_l3, "compatible", &bytes);
		if (count != 2 || native_l3 < 0 || !l3_handle || !text || bytes != (int)sizeof(l3_compat) ||
		    memcmp(text, l3_compat, bytes) || uke_bwmon_properties(fdt, native_l3, l3_props, ARRAY_SIZE(l3_props)) ||
		    fdt_first_subnode(fdt, native_l3) != -FDT_ERR_NOTFOUND ||
		    uke_bwmon_cells(fdt, native_l3, "reg", native_l3_reg, 2) ||
		    uke_bwmon_cells(fdt, native_l3, "clocks", clock_handles, 4) ||
		    uke_bwmon_cells(fdt, native_l3, "#interconnect-cells", one, 1))
			return -FDT_ERR_BADVALUE;
		text = (const char *)fdt_getprop(fdt, native_l3, "clock-names", &bytes);
		if (!text || bytes != (int)sizeof("xo\0alternate") || memcmp(text, "xo\0alternate", bytes))
			return -FDT_ERR_BADVALUE;
		icc[0] = gem; icc[1] = 2; icc[2] = UKE_BWMON_ACTIVE_ONLY;
		icc[3] = gem; icc[4] = 555; icc[5] = UKE_BWMON_ACTIVE_ONLY;
		icc[6] = l3_handle; icc[7] = 0; icc[8] = l3_handle; icc[9] = 1;
		if (uke_bwmon_cells(fdt, node, "interconnects", icc, 10))
			return -FDT_ERR_BADVALUE;
		opps = fdt_subnode_offset(fdt, node, "opp-table");
		opp_handle = fdt_get_phandle(fdt, opps);
		if (opps < 0 || !opp_handle || uke_bwmon_properties(fdt, opps, table_props, ARRAY_SIZE(table_props)) ||
		    fdt_node_check_compatible(fdt, opps, "operating-points-v2") ||
		    uke_bwmon_cells(fdt, node, "operating-points-v2", &opp_handle, 1))
			return -FDT_ERR_BADVALUE;
		count = 0; fdt_for_each_subnode(child, fdt, opps) { count++; }
		if (count != ARRAY_SIZE(frequencies))
			return -FDT_ERR_BADVALUE;
		for (i = 0; i < ARRAY_SIZE(frequencies); i++) {
			unsigned int peaks[] = { frequencies[i] * 16, mapping[i * 2 + 1] * 32 };

			snprintf(name, sizeof(name), "opp-%u", frequencies[i]);
			child = fdt_subnode_offset(fdt, opps, name);
			if (child < 0 || uke_bwmon_cells(fdt, child, "opp-peak-kBps", peaks, 2) ||
			    uke_bwmon_properties(fdt, child, peak_props, ARRAY_SIZE(peak_props)))
				return -FDT_ERR_BADVALUE;
		}
		for (i = 0; i < ARRAY_SIZE(obsolete); i++)
			if (fdt_getprop(fdt, node, obsolete[i], NULL))
				return -FDT_ERR_BADVALUE;
		return uke_bwmon_mc_tags(fdt, gem);
	}
	ret = uke_bwmon_mc_tags(fdt, gem);
	if (ret)
		return ret;
	native_l3 = fdt_add_subnode(fdt, fdt_path_offset(fdt, "/soc"), "interconnect@17d90000");
	if (native_l3 < 0)
		return native_l3;
	ret = fdt_generate_phandle(fdt, &l3_handle);
	if (ret)
		return ret;
	for (i = 0; i < 4; i++) wire[i] = cpu_to_fdt32(clock_handles[i]);
	if ((ret = fdt_setprop(fdt, native_l3, "clocks", wire, 16)) ||
	    (ret = fdt_setprop(fdt, native_l3, "clock-names", "xo\0alternate", sizeof("xo\0alternate"))) ||
	    (ret = fdt_setprop(fdt, native_l3, "compatible", l3_compat, sizeof(l3_compat))) ||
	    (ret = fdt_setprop_u32(fdt, native_l3, "phandle", l3_handle)) ||
	    (ret = fdt_setprop_u32(fdt, native_l3, "#interconnect-cells", 1)))
		return ret;
	wire[0] = cpu_to_fdt32(native_l3_reg[0]); wire[1] = cpu_to_fdt32(native_l3_reg[1]);
	ret = fdt_setprop(fdt, native_l3, "reg", wire, 8);
	if (ret)
		return ret;
	node = fdt_path_offset(fdt, path);
	ret = fdt_setprop(fdt, node, "compatible", mon_compat, sizeof(mon_compat));
	if (ret)
		return ret;
	for (i = 0; i < ARRAY_SIZE(obsolete); i++) {
		ret = fdt_delprop(fdt, node, obsolete[i]);
		if (ret && ret != -FDT_ERR_NOTFOUND)
			return ret;
	}
	wire[0] = cpu_to_fdt32(new_reg[0]); wire[1] = cpu_to_fdt32(new_reg[1]);
	ret = fdt_setprop(fdt, node, "reg", wire, 8);
	if (ret)
		return ret;
	icc[0] = gem; icc[1] = 2; icc[2] = UKE_BWMON_ACTIVE_ONLY;
	icc[3] = gem; icc[4] = 555; icc[5] = UKE_BWMON_ACTIVE_ONLY;
	icc[6] = l3_handle; icc[7] = 0; icc[8] = l3_handle; icc[9] = 1;
	for (i = 0; i < 10; i++) wire[i] = cpu_to_fdt32(icc[i]);
	ret = fdt_setprop(fdt, node, "interconnects", wire, sizeof(wire));
	if (ret)
		return ret;
	opps = fdt_add_subnode(fdt, node, "opp-table");
	if (opps < 0)
		return opps;
	ret = fdt_setprop_string(fdt, opps, "compatible", "operating-points-v2");
	if (ret || (ret = fdt_generate_phandle(fdt, &opp_handle)) ||
	    (ret = fdt_setprop_u32(fdt, opps, "phandle", opp_handle)))
		return ret;
	node = fdt_path_offset(fdt, path);
	ret = fdt_setprop_u32(fdt, node, "operating-points-v2", opp_handle);
	if (ret)
		return ret;
	for (i = 0; i < ARRAY_SIZE(frequencies); i++) {
		node = fdt_path_offset(fdt, path); opps = fdt_subnode_offset(fdt, node, "opp-table");
		snprintf(name, sizeof(name), "opp-%u", frequencies[i]);
		child = fdt_add_subnode(fdt, opps, name);
		if (child < 0)
			return child;
		wire[0] = cpu_to_fdt32(frequencies[i] * 16);
		wire[1] = cpu_to_fdt32(mapping[i * 2 + 1] * 32);
		ret = fdt_setprop(fdt, child, "opp-peak-kBps", wire, 8);
		if (ret)
			return ret;
	}
	return 0;
}
