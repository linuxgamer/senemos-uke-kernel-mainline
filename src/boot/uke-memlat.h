/* SPDX-License-Identifier: GPL-2.0-only */
/* Reuse the admitted native CPU BWMON's LLCC/L3 paths, retaining OEM maps. */
static int UKE_INIT uke_memlat_apply(void *fdt)
{
	static const char path[] = "/soc/qcom,memlat";
	static const char names[] = "llcc\0l3";
	static const char *const props[] = {
		"compatible", "status", "phandle", "linux,phandle",
		"interconnects", "interconnect-names"
	};
	const void *value;
	fdt32_t paths[10];
	int node, monitor, bytes, ret;
	bool native;

	if (fdt_node_check_compatible(fdt, 0, "xiaomi,uke") ||
	    fdt_node_check_compatible(fdt, 0, "qcom,sm7675"))
		return -FDT_ERR_BADVALUE;
	node = fdt_path_offset(fdt, path);
	if (node == -FDT_ERR_NOTFOUND)
		return 0;
	if (node < 0 || uke_bwmon_properties(fdt, node, props, ARRAY_SIZE(props)))
		return -FDT_ERR_BADVALUE;
	ret = uke_cpu_bwmon_status(fdt, node);
	if (ret)
		return ret == 1 ? 0 : ret;
	native = !fdt_node_check_compatible(fdt, node, "xiaomi,uke-memlat");
	value = fdt_getprop(fdt, node, "compatible", &bytes);
	if (!value || (native ? (bytes != sizeof("xiaomi,uke-memlat") ||
	    memcmp(value, "xiaomi,uke-memlat", bytes)) :
	    (bytes != sizeof("qcom,memlat") || memcmp(value, "qcom,memlat", bytes))))
		return -FDT_ERR_BADVALUE;
	monitor = fdt_path_offset(fdt, "/soc/qcom,bwmon-llcc@240B7300");
	if (monitor < 0 || uke_cpu_bwmon_status(fdt, monitor) ||
	    fdt_node_check_compatible(fdt, monitor, "qcom,sm7675-cpu-bwmon"))
		return -FDT_ERR_BADVALUE;
	value = fdt_getprop(fdt, monitor, "interconnects", &bytes);
	if (!value || bytes != sizeof(paths))
		return -FDT_ERR_BADVALUE;
	memcpy(paths, value, sizeof(paths));
	/* uke_cpu_bwmon_apply has validated every endpoint, tag and provider cell. */
	value = fdt_getprop(fdt, node, "interconnects", &bytes);
	if (native ? (!value || bytes != sizeof(paths) || memcmp(value, paths, bytes)) : value != NULL)
		return -FDT_ERR_BADVALUE;
	value = fdt_getprop(fdt, node, "interconnect-names", &bytes);
	if (native ? (!value || bytes != sizeof(names) || memcmp(value, names, bytes)) : value != NULL)
		return -FDT_ERR_BADVALUE;
	if (fdt_subnode_offset(fdt, node, "llcc") < 0 || fdt_subnode_offset(fdt, node, "l3") < 0)
		return -FDT_ERR_BADVALUE;
	ret = fdt_setprop(fdt, node, "interconnects", paths, sizeof(paths));
	if (ret)
		return ret;
	node = fdt_path_offset(fdt, path);
	ret = fdt_setprop(fdt, node, "interconnect-names", names, sizeof(names));
	if (ret)
		return ret;
	node = fdt_path_offset(fdt, path);
	return fdt_setprop_string(fdt, node, "compatible", "xiaomi,uke-memlat");
}
