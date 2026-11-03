/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef UKE_RTC_FDT_H
#define UKE_RTC_FDT_H
static int UKE_INIT uke_rtc_secure_offset(void *fdt)
{
	const char *path = "/soc/qcom,spmi@c42d000/qcom,pmk8550@0/rtc@6100";
	const fdt32_t *reg;
	int node, size;

	if (fdt_node_check_compatible(fdt, 0, "xiaomi,uke") ||
	    fdt_node_check_compatible(fdt, 0, "qcom,sm7675"))
		return -FDT_ERR_BADVALUE;
	node = fdt_path_offset(fdt, path);
	if (node < 0 || fdt_node_check_compatible(fdt, node, "qcom,pmk8350-rtc"))
		return -FDT_ERR_BADVALUE;
	reg = fdt_getprop(fdt, node, "reg", &size);
	if (!reg || size != 8 || fdt32_to_cpu(reg[0]) != 0x6100 ||
	    fdt32_to_cpu(reg[1]) != 0x6200)
		return -FDT_ERR_BADVALUE;
	if (fdt_getprop(fdt, node, "allow-set-time", NULL) ||
	    fdt_getprop(fdt, node, "nvmem-cells", NULL) ||
	    fdt_getprop(fdt, node, "nvmem-cell-names", NULL))
		return -FDT_ERR_BADVALUE;
	return fdt_setprop(fdt, node, "qcom,uefi-rtc-info", NULL, 0);
}
#endif
