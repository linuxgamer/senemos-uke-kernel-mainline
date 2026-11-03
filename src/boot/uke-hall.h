/* SPDX-License-Identifier: GPL-2.0-only */
/* Preserve exact Uke remote hall events without acquiring physical GPIOs. */
static int UKE_INIT uke_hall(void *fdt)
{
	static const struct {
		const char *child, *entry, *node, *label, *smem;
		unsigned int code;
	} switches[] = {
		{ "lid_hall", "qcom,hall-in-lid", "hall-lid", "Uke Hall Lid", "mi_hall_lid", 0 },
		{ "table_hall", "qcom,hall-in-table", "hall-tablet-mode", "Uke Hall Tablet Mode", "mi_hall_table", 1 },
	};
	static const char names[] = "open\0closed";
	unsigned int i;
	int parent = fdt_path_offset(fdt, "/soc/xiaomi_hall"), child, entry, node, bytes, ret;
	const fdt32_t *value;
	fdt32_t irq[6];
	char path[128];

	if (parent < 0 || fdt_node_check_compatible(fdt, parent, "xiaomi-hall"))
		return -FDT_ERR_BADVALUE;
	for (i = 0; i < sizeof(switches) / sizeof(switches[0]); i++) {
		snprintf(path, sizeof(path), "/soc/xiaomi_hall/%s", switches[i].child);
		child = fdt_path_offset(fdt, path);
		value = fdt_getprop(fdt, child, "linux,code", &bytes);
		if (!value || bytes != 4 || fdt32_to_cpu(*value) != switches[i].code)
			return -FDT_ERR_BADVALUE;
		value = fdt_getprop(fdt, child, "linux,input-type", &bytes);
		if (!value || bytes != 4 || fdt32_to_cpu(*value) != 5)
			return -FDT_ERR_BADVALUE;
		value = fdt_getprop(fdt, child, "interrupts-extended", &bytes);
		if (!value || bytes != sizeof(irq))
			return -FDT_ERR_BADVALUE;
		memcpy(irq, value, sizeof(irq));
		snprintf(path, sizeof(path), "/soc/qcom,smp2p-adsp/%s", switches[i].entry);
		entry = fdt_path_offset(fdt, path);
		{
			const char *name = fdt_getprop(fdt, entry, "qcom,entry-name", &bytes);
			if (!name || bytes != (int)strlen(switches[i].smem) + 1 ||
			    strcmp(name, switches[i].smem))
				return -FDT_ERR_BADVALUE;
		}
		value = fdt_getprop(fdt, entry, "#interrupt-cells", &bytes);
		if (!value || bytes != 4 || fdt32_to_cpu(*value) != 2)
			return -FDT_ERR_BADVALUE;
		if (entry < 0 || !fdt_get_phandle(fdt, entry) ||
		    fdt32_to_cpu(irq[0]) != fdt_get_phandle(fdt, entry) ||
		    irq[3] != irq[0] || fdt32_to_cpu(irq[1]) != 0 ||
		    fdt32_to_cpu(irq[4]) != 1 || irq[2] || irq[5])
			return -FDT_ERR_BADVALUE;
		/* OEM requests rising edges; retain the same paired event contract. */
		irq[2] = irq[5] = cpu_to_fdt32(1);
		node = fdt_add_subnode(fdt, 0, switches[i].node);
		if (node < 0)
			return node;
		ret = fdt_setprop_string(fdt, node, "compatible", "qcom,smp2p-switch");
		if (ret)
			return ret;
		ret = fdt_setprop_string(fdt, node, "label", switches[i].label);
		if (ret)
			return ret;
		ret = fdt_setprop_u32(fdt, node, "linux,code", switches[i].code);
		if (ret)
			return ret;
		ret = fdt_setprop(fdt, node, "interrupt-names", names, sizeof(names));
		if (ret)
			return ret;
		ret = fdt_setprop(fdt, node, "interrupts-extended", irq, sizeof(irq));
		if (ret)
			return ret;
	}
	node = fdt_path_offset(fdt, "/hall-lid");
	ret = fdt_setprop(fdt, node, "wakeup-source", NULL, 0);
	if (ret)
		return ret;
	node = fdt_path_offset(fdt, "/soc/qcom,smp2p-adsp");
	ret = fdt_setprop(fdt, node, "qcom,selective-wakeup", NULL, 0);
	if (ret)
		return ret;
	parent = fdt_path_offset(fdt, "/soc/xiaomi_hall");
	return fdt_setprop_string(fdt, parent, "status", "disabled");
}
