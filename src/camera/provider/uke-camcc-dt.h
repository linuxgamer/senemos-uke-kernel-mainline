/* SPDX-License-Identifier: GPL-2.0-only */
/* Controller bring-up graph from exact Uke OEM DT; camera capture is separate. */
#ifndef UKE_CAMCC_DT_H
#define UKE_CAMCC_DT_H

/* OEM consumers stay disabled until their native graph is admitted. Disabling
 * an OF node does not stop firmware hardware; the CRM driver guard is required.
 */
static const struct {
	const char *path;
	const char *compatible;
} uke_camcc_legacy[] = {
	{ "/soc/qcom,ipe0@ac42000", "qcom,cam-ipe680" },
	{ "/soc/qcom,ife2@ac80000", "qcom,vfe860" },
	{ "/soc/rsc@add4000", "qcom,rpmh-rsc" },
	{ "/soc/qcom,rt-cdm3@ac28000", "qcom,cam-rt-cdm2_1" },
	{ "/soc/clock-controller@0", "qcom,cliffs-debugcc" },
	{ "/soc/qcom,csid1@acb9000", "qcom,csid860" },
	{ "/soc/qcom,jpegenc0@ac2a000", "qcom,cam_jpeg_enc_780" },
	{ "/soc/qcom,csiphy4@acec000", "qcom,csiphy-v2.2.1" },
	{ "/soc/qcom,cre@acfc000", "qcom,cre" },
	{ "/soc/qcom,csid0@acb7000", "qcom,csid860" },
	{ "/soc/qcom,rt-cdm4@ac29000", "qcom,cam-rt-cdm2_1" },
	{ "/soc/qcom,csiphy3@acea000", "qcom,csiphy-v2.2.1" },
	{ "/soc/qcom,bps@ac2c000", "qcom,cam-bps880" },
	{ "/soc/qcom,icp@ac00000", "qcom,cam-icp_v2_1" },
	{ "/soc/qcom,rt-cdm0@ac25000", "qcom,cam-rt-cdm2_1" },
	{ "/soc/qcom,csiphy2@ace8000", "qcom,csiphy-v2.2.1" },
	{ "/soc/qcom,cam-cpas@ac13000", "qcom,cam-cpas" },
	{ "/soc/qcom,tpg13@acf6000", "qcom,cam-tpg104" },
	{ "/soc/qcom,jpegdma0@ac2b000", "qcom,cam_jpeg_dma_780" },
	{ "/soc/qcom,cci0@ac15000/qcom,cam-sensor0", "qcom,cam-sensor" },
	{ "/soc/qcom,cci0@ac15000", "qcom,cci" },
	{ "/soc/qcom,cci0@ac15000/qcom,eeprom0", "qcom,eeprom" },
	{ "/soc/qcom,cci0@ac15000/qcom,actuator0", "qcom,actuator" },
	{ "/soc/qcom,csiphy1@ace6000", "qcom,csiphy-v2.2.1" },
	{ "/soc/qcom,rt-cdm1@ac26000", "qcom,cam-rt-cdm2_1" },
	{ "/soc/qcom,qupv3_1_geni_se@8c0000/i2c@880000/qcom,cam-sensor1", "qcom,cam-i2c-sensor" },
	{ "/soc/qcom,qupv3_1_geni_se@8c0000/i2c@880000/qcom,eeprom1", "qcom,cam-i2c-eeprom" },
	{ "/soc/qcom,csid-lite1@accf000", "qcom,csid-lite860" },
	{ "/soc/qcom,sfe1@aca6000", "qcom,sfe860" },
	{ "/soc/crm@add7000", "qcom,cam-crm" },
	{ "/soc/qcom,ife-lite1@accf000", "qcom,vfe-lite860" },
	{ "/soc/qcom,ife0@ac62000", "qcom,vfe860" },
	{ "/soc/qcom,tpg14@acf7000", "qcom,cam-tpg104" },
	{ "/soc/qcom,csiphy0@ace4000", "qcom,csiphy-v2.2.1-n16t" },
	{ "/soc/qcom,csid-lite0@acca000", "qcom,csid-lite860" },
	{ "/soc/qcom,ife-lite0@acca000", "qcom,vfe-lite860" },
	{ "/soc/qcom,cci1@ac16000", "qcom,cci" },
	{ "/soc/qcom,rt-cdm2@ac27000", "qcom,cam-rt-cdm2_1" },
	{ "/soc/qcom,ife1@ac71000", "qcom,vfe860" },
	{ "/soc/qcom,sfe0@ac9e000", "qcom,sfe860" },
	{ "/soc/qcom,tpg15@acf8000", "qcom,cam-tpg104" },
	{ "/soc/qcom,csid2@acbb000", "qcom,csid860" },
};

static int UKE_INIT uke_camcc_clock_cells(const void *fdt, unsigned int phandle)
{
	int node = fdt_node_offset_by_phandle(fdt, phandle), size;
	const fdt32_t *cells;

	if (node < 0)
		return -FDT_ERR_BADPHANDLE;
	cells = fdt_getprop(fdt, node, "#clock-cells", &size);
	if (!cells || size != 4 || fdt32_to_cpu(*cells) > 4)
		return -FDT_ERR_BADNCELLS;
	return fdt32_to_cpu(*cells);
}

static int UKE_INIT uke_camcc_known_consumer(const void *fdt, int node)
{
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(uke_camcc_legacy); i++)
		if (node == fdt_path_offset(fdt, uke_camcc_legacy[i].path))
			return 1;
	return 0;
}

/* Admit every clock tuple, including arguments, before any graph mutation. */
static int UKE_INIT uke_camcc_consumers(const void *fdt, unsigned int cam_phandle)
{
	int node = -1, size;
	const fdt32_t *clocks;

	while ((node = fdt_next_node(fdt, node, NULL)) >= 0) {
		int i, count;

		clocks = fdt_getprop(fdt, node, "clocks", &size);
		if (!clocks)
			continue;
		if (size % 4)
			return -FDT_ERR_BADVALUE;
		for (i = 0; i < size / 4; i += count + 1) {
			unsigned int phandle = fdt32_to_cpu(clocks[i]);

			count = phandle ? uke_camcc_clock_cells(fdt, phandle) : 0;
			if (count < 0 || count > size / 4 - i - 1)
				return -FDT_ERR_BADNCELLS;
			if (phandle == cam_phandle && !uke_camcc_known_consumer(fdt, node))
				return -FDT_ERR_BADPHANDLE;
		}
	}
	return node == -FDT_ERR_NOTFOUND ? 0 : node;
}

static int UKE_INIT uke_camcc_controller_graph(void *fdt)
{
	static const char path[] = "/soc/clock-controller@ade0000";
	static const char old_names[] = "bi_tcxo\0bi_tcxo_ao\0sleep_clk\0iface";
	static const char new_names[] = "iface\0bi_tcxo\0bi_tcxo_ao\0sleep_clk";
	static const char reg_names[] = "cc_base\0crm";
	static const unsigned int addresses[] = { 0xade0000, 0x20000, 0xadd7000, 0x2000 };
	fdt32_t old_clocks[7], new_clocks[7], registers[4];
	const fdt32_t *values;
	const char *names;
	unsigned int i, cam_phandle;
	int node, parent, size, native, ret;

	if (fdt_node_check_compatible(fdt, 0, "xiaomi,uke") ||
	    fdt_node_check_compatible(fdt, 0, "qcom,sm7675"))
		return -FDT_ERR_BADVALUE;
	node = fdt_path_offset(fdt, path);
	if (node < 0)
		return node;
	parent = fdt_parent_offset(fdt, node);
	if (fdt_address_cells(fdt, parent) != 1 || fdt_size_cells(fdt, parent) != 1)
		return -FDT_ERR_BADNCELLS;
	native = !fdt_node_check_compatible(fdt, node, "qcom,sm7675-camcc");
	if (!native && fdt_node_check_compatible(fdt, node, "qcom,cliffs-camcc"))
		return -FDT_ERR_BADVALUE;
	values = fdt_getprop(fdt, node, "reg", &size);
	if (!values || size != (native ? 16 : 8))
		return -FDT_ERR_BADVALUE;
	for (i = 0; i < (native ? 4U : 2U); i++)
		if (fdt32_to_cpu(values[i]) != addresses[i])
			return -FDT_ERR_BADVALUE;
	cam_phandle = fdt_get_phandle(fdt, node);
	if (!cam_phandle || fdt_getprop(fdt, node, "power-domains", NULL) ||
	    fdt_getprop(fdt, node, "protected-clocks", NULL) ||
	    uke_camcc_clock_cells(fdt, cam_phandle) != 1)
		return -FDT_ERR_BADVALUE;
	values = fdt_getprop(fdt, node, "#reset-cells", &size);
	if (!values || size != 4 || fdt32_to_cpu(*values) != 1)
		return -FDT_ERR_BADNCELLS;
	names = fdt_getprop(fdt, node, "clock-names", &size);
	if (!names || size != (int)sizeof(old_names) ||
	    memcmp(names, native ? new_names : old_names, sizeof(old_names)))
		return -FDT_ERR_BADVALUE;
	values = fdt_getprop(fdt, node, "clocks", &size);
	if (!values || size != (int)sizeof(old_clocks))
		return -FDT_ERR_BADVALUE;
	if (native) {
		for (i = 0; i < 5; i++)
			old_clocks[i] = values[i + 2];
		old_clocks[5] = values[0]; old_clocks[6] = values[1];
	} else {
		memcpy(old_clocks, values, sizeof(old_clocks));
	}
	if (old_clocks[0] != old_clocks[2] || fdt32_to_cpu(old_clocks[1]) != 0 ||
	    fdt32_to_cpu(old_clocks[3]) != 1 || fdt32_to_cpu(old_clocks[6]) != 10 ||
	    uke_camcc_clock_cells(fdt, fdt32_to_cpu(old_clocks[0])) != 1 ||
	    uke_camcc_clock_cells(fdt, fdt32_to_cpu(old_clocks[4])) != 0 ||
	    uke_camcc_clock_cells(fdt, fdt32_to_cpu(old_clocks[5])) != 1)
		return -FDT_ERR_BADVALUE;
	for (i = 0; i < ARRAY_SIZE(uke_camcc_legacy); i++) {
		node = fdt_path_offset(fdt, uke_camcc_legacy[i].path);
		if (node < 0 || fdt_node_check_compatible(fdt, node, uke_camcc_legacy[i].compatible))
			return -FDT_ERR_BADVALUE;
	}
	ret = uke_camcc_consumers(fdt, cam_phandle);
	if (ret)
		return ret;
	for (i = 0; i < ARRAY_SIZE(uke_camcc_legacy); i++) {
		node = fdt_path_offset(fdt, uke_camcc_legacy[i].path);
		ret = fdt_setprop_string(fdt, node, "status", "disabled");
		if (ret)
			return ret;
	}
	node = fdt_path_offset(fdt, path);
	new_clocks[0] = old_clocks[5]; new_clocks[1] = old_clocks[6];
	for (i = 0; i < 5; i++)
		new_clocks[i + 2] = old_clocks[i];
	for (i = 0; i < 4; i++)
		registers[i] = cpu_to_fdt32(addresses[i]);
#define UKE_CAMCC_SET(call) do { ret = (call); if (ret) return ret; } while (0)
	UKE_CAMCC_SET(fdt_setprop_string(fdt, node, "compatible", "qcom,sm7675-camcc"));
	UKE_CAMCC_SET(fdt_setprop(fdt, node, "reg", registers, sizeof(registers)));
	UKE_CAMCC_SET(fdt_setprop(fdt, node, "reg-names", reg_names, sizeof(reg_names)));
	UKE_CAMCC_SET(fdt_setprop(fdt, node, "clocks", new_clocks, sizeof(new_clocks)));
	UKE_CAMCC_SET(fdt_setprop(fdt, node, "clock-names", new_names, sizeof(new_names)));
	UKE_CAMCC_SET(fdt_setprop_u32(fdt, node, "#power-domain-cells", 1));
	UKE_CAMCC_SET(fdt_setprop_string(fdt, node, "status", "okay"));
#undef UKE_CAMCC_SET
	ret = fdt_delprop(fdt, node, "reg-name");
	if (ret && ret != -FDT_ERR_NOTFOUND)
		return ret;
	ret = fdt_delprop(fdt, node, "qcom,cam_crm-crmc");
	return ret == -FDT_ERR_NOTFOUND ? 0 : ret;
}

#endif /* UKE_CAMCC_DT_H */
