/* SPDX-License-Identifier: GPL-2.0-only */
/* Exact Uke transport and read-only EEPROM; sensor/capture admission is separate. */
#ifndef UKE_FRONT_EEPROM_DT_H
#define UKE_FRONT_EEPROM_DT_H

#define UKE_FRONT_QUP "/soc/qcom,qupv3_1_geni_se@8c0000"
#define UKE_FRONT_BUS UKE_FRONT_QUP "/i2c@880000"
#define UKE_FRONT_OLD UKE_FRONT_BUS "/qcom,eeprom1"
#define UKE_FRONT_NEW UKE_FRONT_BUS "/eeprom@51"
#define UKE_FRONT_L20 "/soc/rsc@17a00000/drv@2/rpmh-regulator-ldob20/regulator-pmxr2230-l20"
#define UKE_FRONT_TLMM "/soc/pinctrl@f000000"
#define UKE_FRONT_PIN UKE_FRONT_TLMM "/qupv3_se8_i2c_pins/"

static int UKE_INIT uke_front_bytes(const void *fdt, int node, const char *name,
				  const void *expected, int bytes)
{
	int size;
	const void *value = fdt_getprop(fdt, node, name, &size);

	return value && size == bytes && !memcmp(value, expected, bytes);
}

static int UKE_INIT uke_front_u32(const void *fdt, int node, const char *name,
				unsigned int expected)
{
	fdt32_t value = cpu_to_fdt32(expected);

	return uke_front_bytes(fdt, node, name, &value, sizeof(value));
}

static unsigned int UKE_INIT uke_front_phandle(const void *fdt, const char *path)
{
	int node = fdt_path_offset(fdt, path);

	return node < 0 ? 0 : fdt_get_phandle(fdt, node);
}

static int UKE_INIT uke_front_disabled(const void *fdt, int node)
{
	return uke_front_bytes(fdt, node, "status", "disabled", sizeof("disabled"));
}

static int UKE_INIT uke_front_pin(const void *fdt, const char *path,
				const char *pins, int bytes, const char *function,
				const char *bias)
{
	int node = fdt_path_offset(fdt, path), mux, config;

	if (node < 0)
		return 0;
	mux = fdt_subnode_offset(fdt, node, "mux");
	config = fdt_subnode_offset(fdt, node, "config");
	return mux >= 0 && config >= 0 &&
		uke_front_bytes(fdt, mux, "pins", pins, bytes) &&
		uke_front_bytes(fdt, config, "pins", pins, bytes) &&
		uke_front_bytes(fdt, mux, "function", function, strlen(function) + 1) &&
		uke_front_u32(fdt, config, "drive-strength", 2) &&
		uke_front_bytes(fdt, config, bias, "", 0) &&
		!fdt_getprop(fdt, config, !strcmp(bias, "bias-disable") ?
			"bias-pull-down" : "bias-disable", NULL) &&
		!fdt_getprop(fdt, config, "bias-pull-up", NULL);
}

/* Validate the whole preimage before mutation. The caller owns a private FDT
 * copy and discards it on any allocation/set-property failure.
 */
static int UKE_INIT uke_front_eeprom_graph(void *fdt)
{
	static const char icc_names[] = "qup-core\0qup-config\0qup-memory";
	static const char dma_names[] = "tx\0rx";
	static const char pin_names[] = "default\0sleep";
	static const char *const remove[] = {
		"cell-index", "cam_vio-supply", "regulator-names", "rgltr-cntrl-support",
		"rgltr-min-voltage", "rgltr-max-voltage", "rgltr-load-current", "name"
	};
	static const char *const forbidden[] = {
		"wp-gpios", "pagesize", "no-read-rollover", "num-addresses",
		"vin-supply", "power-domains", "clocks", "resets", "reset-gpios"
	};
	const unsigned int regs[] = { 0x880000, 0x4000 };
	const unsigned int irq[] = { 0, 373, 4 };
	fdt32_t clocks[2], old_dma[12], new_dma[8], pins[2], sleep[1], icc[14];
	unsigned int gcc, gpi, l20, clkvirt, gem, cnoc, aggre, mc, i;
	int bus, eeprom, qup, node, native, size, ret, child, symbols, symbol_present;
	const fdt32_t *value;

	if (fdt_node_check_compatible(fdt, 0, "xiaomi,uke") ||
	    fdt_node_check_compatible(fdt, 0, "qcom,sm7675"))
		return -FDT_ERR_BADVALUE;
	bus = fdt_path_offset(fdt, UKE_FRONT_BUS);
	qup = fdt_path_offset(fdt, UKE_FRONT_QUP);
	if (bus < 0 || qup < 0 || fdt_parent_offset(fdt, bus) != qup ||
	    fdt_node_check_compatible(fdt, qup, "qcom,geni-se-qup") ||
	    !uke_front_bytes(fdt, qup, "status", "okay", sizeof("okay")) ||
	    !uke_front_u32(fdt, qup, "#address-cells", 1) ||
	    !uke_front_u32(fdt, qup, "#size-cells", 1) ||
	    !uke_front_u32(fdt, bus, "#address-cells", 1) ||
	    !uke_front_u32(fdt, bus, "#size-cells", 0) ||
	    fdt_getprop(fdt, qup, "firmware-name", NULL) ||
	    fdt_getprop(fdt, bus, "firmware-name", NULL) ||
	    fdt_getprop(fdt, bus, "power-domains", NULL))
		return -FDT_ERR_BADVALUE;
	value = fdt_getprop(fdt, qup, "reg", &size);
	if (!value || size != 8 || fdt32_to_cpu(value[0]) != 0x8c0000 ||
	    fdt32_to_cpu(value[1]) != 0x2000)
		return -FDT_ERR_BADVALUE;
	value = fdt_getprop(fdt, bus, "reg", &size);
	if (!value || size != 8)
		return -FDT_ERR_BADVALUE;
	for (i = 0; i < ARRAY_SIZE(regs); i++)
		if (fdt32_to_cpu(value[i]) != regs[i])
			return -FDT_ERR_BADVALUE;
	value = fdt_getprop(fdt, bus, "interrupts", &size);
	if (!value || size != 12)
		return -FDT_ERR_BADVALUE;
	for (i = 0; i < ARRAY_SIZE(irq); i++)
		if (fdt32_to_cpu(value[i]) != irq[i])
			return -FDT_ERR_BADVALUE;
	native = !fdt_node_check_compatible(fdt, bus, "qcom,geni-i2c");
	if ((!native && fdt_node_check_compatible(fdt, bus, "qcom,i2c-geni")) ||
	    (!native && !uke_front_disabled(fdt, bus)) ||
	    !uke_front_bytes(fdt, bus, "clock-names", native ? "se" : "se-clk",
			     native ? sizeof("se") : sizeof("se-clk")))
		return -FDT_ERR_BADVALUE;
	gcc = uke_front_phandle(fdt, "/soc/clock-controller@100000");
	gpi = uke_front_phandle(fdt, "/soc/qcom,gpi-dma@800000");
	l20 = uke_front_phandle(fdt, UKE_FRONT_L20);
	if (!gcc || !gpi || !l20 ||
	    fdt_node_check_compatible(fdt, fdt_node_offset_by_phandle(fdt, gcc), "qcom,cliffs-gcc") ||
	    !uke_front_u32(fdt, fdt_node_offset_by_phandle(fdt, gcc), "#clock-cells", 1))
		return -FDT_ERR_BADPHANDLE;
	{
		unsigned int smmu = uke_front_phandle(fdt, "/soc/apps-smmu@15000000");
		fdt32_t wrapper_clocks[] = {cpu_to_fdt32(gcc), cpu_to_fdt32(106),
			cpu_to_fdt32(gcc), cpu_to_fdt32(107)};
		fdt32_t wrapper_iommu[] = {cpu_to_fdt32(smmu), cpu_to_fdt32(0x423), 0};
		fdt32_t gpi_iommu[] = {cpu_to_fdt32(smmu), cpu_to_fdt32(0x436), 0};
		fdt32_t gpi_reg[] = {cpu_to_fdt32(0x800000), cpu_to_fdt32(0x60000)};
		static const char wrapper_names[] = "m-ahb\0s-ahb";

		if (!smmu || !uke_front_u32(fdt, fdt_node_offset_by_phandle(fdt, smmu), "#iommu-cells", 2) ||
		    !uke_front_bytes(fdt, qup, "clocks", wrapper_clocks, sizeof(wrapper_clocks)) ||
		    !uke_front_bytes(fdt, qup, "clock-names", wrapper_names, sizeof(wrapper_names)) ||
		    !uke_front_bytes(fdt, qup, "iommus", wrapper_iommu, sizeof(wrapper_iommu)) ||
		    !uke_front_bytes(fdt, fdt_node_offset_by_phandle(fdt, gpi), "iommus", gpi_iommu, sizeof(gpi_iommu)) ||
		    !uke_front_bytes(fdt, fdt_node_offset_by_phandle(fdt, gpi), "reg", gpi_reg, sizeof(gpi_reg)))
			return -FDT_ERR_BADVALUE;
	}
	node = fdt_node_offset_by_phandle(fdt, gpi);
	if (fdt_node_check_compatible(fdt, node, "qcom,sm8450-gpi-dma") ||
	    !uke_front_u32(fdt, node, "#dma-cells", 3) ||
	    !uke_front_u32(fdt, node, "dma-channels", 12) ||
	    !uke_front_u32(fdt, node, "dma-channel-mask", 0x1e) ||
	    !uke_front_bytes(fdt, node, "status", "okay", sizeof("okay")))
		return -FDT_ERR_BADVALUE;
	clocks[0] = cpu_to_fdt32(gcc); clocks[1] = cpu_to_fdt32(86);
	if (!uke_front_bytes(fdt, bus, "clocks", clocks, sizeof(clocks)) ||
	    !uke_front_bytes(fdt, bus, "dma-names", dma_names, sizeof(dma_names)))
		return -FDT_ERR_BADVALUE;
	for (i = 0; i < 2; i++) {
		old_dma[i * 6] = new_dma[i * 4] = cpu_to_fdt32(gpi);
		old_dma[i * 6 + 1] = new_dma[i * 4 + 1] = cpu_to_fdt32(i);
		old_dma[i * 6 + 2] = new_dma[i * 4 + 2] = 0;
		old_dma[i * 6 + 3] = new_dma[i * 4 + 3] = cpu_to_fdt32(3);
		old_dma[i * 6 + 4] = cpu_to_fdt32(1024);
		old_dma[i * 6 + 5] = 0;
	}
	if (!uke_front_bytes(fdt, bus, "dmas", native ? new_dma : old_dma,
			     native ? sizeof(new_dma) : sizeof(old_dma)))
		return -FDT_ERR_BADVALUE;
	clkvirt = uke_front_phandle(fdt, "/soc/interconnect@0");
	gem = uke_front_phandle(fdt, "/soc/interconnect@24100000");
	cnoc = uke_front_phandle(fdt, "/soc/interconnect@1600000");
	aggre = uke_front_phandle(fdt, "/soc/interconnect@1700000");
	mc = uke_front_phandle(fdt, "/soc/interconnect@1");
	if (!clkvirt || !gem || !cnoc || !aggre || !mc)
		return -FDT_ERR_BADPHANDLE;
	{
		const unsigned int tuple[] = {clkvirt, 37, clkvirt, 573,
			gem, 2, 0, cnoc, 541, aggre, 7, mc, 512, 0};
		const unsigned int providers[] = {clkvirt, gem, cnoc, aggre, mc};
		const unsigned int cells[] = {1, 2, 1, 1, 2};

		for (i = 0; i < ARRAY_SIZE(tuple); i++)
			icc[i] = cpu_to_fdt32(tuple[i]);
		for (i = 0; i < ARRAY_SIZE(providers); i++)
			if (!uke_front_u32(fdt, fdt_node_offset_by_phandle(fdt, providers[i]),
					   "#interconnect-cells", cells[i]))
				return -FDT_ERR_BADNCELLS;
	}
	if (!uke_front_bytes(fdt, bus, "interconnects", icc, sizeof(icc)) ||
	    !uke_front_bytes(fdt, bus, "interconnect-names", icc_names, sizeof(icc_names)))
		return -FDT_ERR_BADVALUE;
	node = fdt_path_offset(fdt, UKE_FRONT_TLMM);
	if (node < 0 || fdt_node_check_compatible(fdt, node, "qcom,cliffs-pinctrl") ||
	    !uke_front_u32(fdt, node, "#gpio-cells", 2))
		return -FDT_ERR_BADVALUE;
	value = fdt_getprop(fdt, node, "reg", &size);
	if (!value || size != 8 || fdt32_to_cpu(value[0]) != 0xf000000 ||
	    fdt32_to_cpu(value[1]) != 0x1000000)
		return -FDT_ERR_BADVALUE;
	pins[0] = cpu_to_fdt32(uke_front_phandle(fdt, UKE_FRONT_PIN "uke_qupv3_se8_i2c_sda_active"));
	pins[1] = cpu_to_fdt32(uke_front_phandle(fdt, UKE_FRONT_PIN "uke_qupv3_se8_i2c_scl_active"));
	sleep[0] = cpu_to_fdt32(uke_front_phandle(fdt, UKE_FRONT_PIN "qupv3_se8_i2c_sleep"));
	if (!pins[0] || !pins[1] || !sleep[0] ||
	    !uke_front_bytes(fdt, bus, "pinctrl-0", pins, sizeof(pins)) ||
	    !uke_front_bytes(fdt, bus, "pinctrl-1", sleep, sizeof(sleep)) ||
	    !uke_front_bytes(fdt, bus, "pinctrl-names", pin_names, sizeof(pin_names)) ||
	    !uke_front_pin(fdt, UKE_FRONT_PIN "uke_qupv3_se8_i2c_sda_active",
			   "gpio0", sizeof("gpio0"), "qup1_se0_l0", "bias-disable") ||
	    !uke_front_pin(fdt, UKE_FRONT_PIN "uke_qupv3_se8_i2c_scl_active",
			   "gpio1", sizeof("gpio1"), "qup1_se0_l1", "bias-disable") ||
	    !uke_front_pin(fdt, UKE_FRONT_PIN "qupv3_se8_i2c_sleep",
			   "gpio0\0gpio1", sizeof("gpio0\0gpio1"), "gpio", "bias-pull-down"))
		return -FDT_ERR_BADVALUE;
	node = fdt_node_offset_by_phandle(fdt, l20);
	if (!uke_front_bytes(fdt, node, "regulator-name", "pmxr2230_l20", sizeof("pmxr2230_l20")) ||
	    !uke_front_u32(fdt, node, "regulator-min-microvolt", 1620000) ||
	    !uke_front_u32(fdt, node, "regulator-max-microvolt", 3544000) ||
	    !uke_front_u32(fdt, node, "qcom,init-voltage", 1620000))
		return -FDT_ERR_BADVALUE;
	node = fdt_parent_offset(fdt, node);
	if (fdt_node_check_compatible(fdt, node, "qcom,rpmh-vrm-regulator") ||
	    !uke_front_bytes(fdt, node, "qcom,resource-name", "ldob20", sizeof("ldob20")) ||
	    !uke_front_bytes(fdt, node, "qcom,regulator-type", "pmic5-ldo", sizeof("pmic5-ldo")))
		return -FDT_ERR_BADVALUE;
	eeprom = fdt_path_offset(fdt, native ? UKE_FRONT_NEW : UKE_FRONT_OLD);
	if (eeprom < 0 || fdt_path_offset(fdt, native ? UKE_FRONT_OLD : UKE_FRONT_NEW) != -FDT_ERR_NOTFOUND ||
	    !fdt_get_phandle(fdt, eeprom) || !uke_front_u32(fdt, eeprom, "reg", 0x51) ||
	    fdt_node_check_compatible(fdt, eeprom, native ? "atmel,24c64" : "qcom,cam-i2c-eeprom"))
		return -FDT_ERR_BADVALUE;
	for (i = 0; i < ARRAY_SIZE(forbidden); i++)
		if (fdt_getprop(fdt, eeprom, forbidden[i], NULL))
			return -FDT_ERR_BADVALUE;
	if (native) {
		if (!uke_front_bytes(fdt, eeprom, "read-only", "", 0) ||
		    !uke_front_u32(fdt, eeprom, "vcc-supply", l20) ||
		    !uke_front_u32(fdt, eeprom, "vcc-microvolt", 1800000) ||
		    !uke_front_u32(fdt, eeprom, "size", 8192) ||
		    !uke_front_u32(fdt, eeprom, "address-width", 16) ||
		    !uke_front_u32(fdt, bus, "clock-frequency", 400000))
			return -FDT_ERR_BADVALUE;
	} else if (!uke_front_u32(fdt, eeprom, "cam_vio-supply", l20) ||
		   !uke_front_u32(fdt, eeprom, "cell-index", 1) ||
		   !uke_front_bytes(fdt, eeprom, "regulator-names", "cam_vio", sizeof("cam_vio")) ||
		   !uke_front_u32(fdt, eeprom, "rgltr-min-voltage", 1800000) ||
		   !uke_front_u32(fdt, eeprom, "rgltr-max-voltage", 1800000) ||
		   !uke_front_u32(fdt, eeprom, "rgltr-load-current", 106000) ||
		   !uke_front_bytes(fdt, eeprom, "rgltr-cntrl-support", "", 0) ||
		   !uke_front_disabled(fdt, eeprom) ||
		   !uke_front_u32(fdt, bus, "qcom,clk-freq-out", 400000)) {
		return -FDT_ERR_BADVALUE;
	}
	/* No other I2C child is admitted by enabling this parent. */
	fdt_for_each_subnode(child, fdt, bus) {
		if (child == eeprom)
			continue;
		if (fdt_node_check_compatible(fdt, child, "qcom,cam-i2c-sensor") ||
		    !uke_front_disabled(fdt, child))
			return -FDT_ERR_BADVALUE;
	}
	if (child != -FDT_ERR_NOTFOUND)
		return child;
	/* The existing general QUP quarantine must precede this late admission. */
	fdt_for_each_subnode(child, fdt, qup) {
		if (child == bus)
			continue;
		value = fdt_getprop(fdt, child, "reg", &size);
		if (value && size >= 4 && fdt32_to_cpu(value[0]) == 0x880000 &&
		    !uke_front_disabled(fdt, child))
			return -FDT_ERR_BADVALUE;
	}
	if (child != -FDT_ERR_NOTFOUND)
		return child;
	symbols = fdt_path_offset(fdt, "/__symbols__");
	symbol_present = symbols >= 0 && fdt_getprop(fdt, symbols, "eeprom_front", NULL);
	if (symbol_present && !uke_front_bytes(fdt, symbols, "eeprom_front",
			native ? UKE_FRONT_NEW : UKE_FRONT_OLD,
			native ? sizeof(UKE_FRONT_NEW) : sizeof(UKE_FRONT_OLD)))
		return -FDT_ERR_BADVALUE;
#define UKE_FRONT_SET(call) do { ret = (call); if (ret) return ret; } while (0)
	if (!native)
		UKE_FRONT_SET(fdt_set_name(fdt, eeprom, "eeprom@51"));
	eeprom = fdt_path_offset(fdt, UKE_FRONT_NEW);
	UKE_FRONT_SET(fdt_setprop_string(fdt, eeprom, "compatible", "atmel,24c64"));
	UKE_FRONT_SET(fdt_setprop_u32(fdt, eeprom, "vcc-supply", l20));
	UKE_FRONT_SET(fdt_setprop_u32(fdt, eeprom, "vcc-microvolt", 1800000));
	UKE_FRONT_SET(fdt_setprop_u32(fdt, eeprom, "size", 8192));
	UKE_FRONT_SET(fdt_setprop_u32(fdt, eeprom, "address-width", 16));
	UKE_FRONT_SET(fdt_setprop(fdt, eeprom, "read-only", NULL, 0));
	UKE_FRONT_SET(fdt_setprop_string(fdt, eeprom, "label", "uke-front-calibration"));
	for (i = 0; i < ARRAY_SIZE(remove); i++) {
		ret = fdt_delprop(fdt, eeprom, remove[i]);
		if (ret && ret != -FDT_ERR_NOTFOUND)
			return ret;
	}
	UKE_FRONT_SET(fdt_setprop_string(fdt, eeprom, "status", "okay"));
	/* Reacquire parent offsets after child growth/name changes. */
	bus = fdt_path_offset(fdt, UKE_FRONT_BUS);
	UKE_FRONT_SET(fdt_setprop_string(fdt, bus, "compatible", "qcom,geni-i2c"));
	UKE_FRONT_SET(fdt_setprop_string(fdt, bus, "clock-names", "se"));
	UKE_FRONT_SET(fdt_setprop(fdt, bus, "dmas", new_dma, sizeof(new_dma)));
	UKE_FRONT_SET(fdt_setprop_u32(fdt, bus, "clock-frequency", 400000));
	ret = fdt_delprop(fdt, bus, "qcom,clk-freq-out");
	if (ret && ret != -FDT_ERR_NOTFOUND)
		return ret;
	ret = fdt_delprop(fdt, bus, "qcom,pm-ctrl-client");
	if (ret && ret != -FDT_ERR_NOTFOUND)
		return ret;
	UKE_FRONT_SET(fdt_setprop_string(fdt, bus, "status", "okay"));
	if (symbol_present) {
		symbols = fdt_path_offset(fdt, "/__symbols__");
		UKE_FRONT_SET(fdt_setprop_string(fdt, symbols, "eeprom_front", UKE_FRONT_NEW));
	}
#undef UKE_FRONT_SET
	return 0;
}
#endif
