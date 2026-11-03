/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef UKE_LIGHTS_H
#define UKE_LIGHTS_H

#define UKE_LIGHT_PMIC "/soc/qcom,spmi@c42d000/qcom,pmxr2230@1"
#define UKE_LIGHT_FLASH UKE_LIGHT_PMIC "/qcom,flash_led@ee00"

static inline int uke_light_cell(const void *fdt, int node, const char *name,
				unsigned int expected)
{
	int bytes;
	const fdt32_t *value = (const fdt32_t *)fdt_getprop(fdt, node, name, &bytes);

	return value && bytes == 4 && fdt32_to_cpu(*value) == expected;
}

static inline int uke_lights_admitted(const void *fdt)
{
	static const char * const colors[] = {"red", "green", "blue"};
	int flash = fdt_path_offset(fdt, UKE_LIGHT_FLASH);
	int rgb = fdt_path_offset(fdt, UKE_LIGHT_PMIC "/qcom,leds@ef00");
	int pwm = fdt_path_offset(fdt, UKE_LIGHT_PMIC "/pwms@e800");
	int camera = fdt_path_offset(fdt, "/soc/qcom,camera-flash0");
	int torch[2], bytes;
	const fdt32_t *value;
	unsigned int i;

	if (flash < 0 || rgb < 0 || pwm < 0 || camera < 0 ||
	    fdt_node_check_compatible(fdt, flash, "qcom,pm8350c-flash-led") ||
	    fdt_node_check_compatible(fdt, rgb, "qcom,tri-led") ||
	    fdt_node_check_compatible(fdt, pwm, "qcom,pwm-lpg") ||
	    !uke_light_cell(fdt, flash, "reg", 0xee00) ||
	    !uke_light_cell(fdt, rgb, "reg", 0xef00) ||
	    !uke_light_cell(fdt, pwm, "reg", 0xe800))
		return 0;
	torch[0] = fdt_subnode_offset(fdt, flash, "qcom,torch_0");
	torch[1] = fdt_subnode_offset(fdt, flash, "qcom,torch_3");
	for (i = 0; i < 2; i++)
		if (torch[i] < 0 || !fdt_get_phandle(fdt, torch[i]) ||
		    !uke_light_cell(fdt, torch[i], "qcom,id", i ? 3 : 0) ||
		    !uke_light_cell(fdt, torch[i], "qcom,max-current-ma", 250) ||
		    !uke_light_cell(fdt, torch[i], "qcom,ires-ua", 5000))
			return 0;
	value = (const fdt32_t *)fdt_getprop(fdt, camera, "torch-source", &bytes);
	if (!value || bytes != 8 ||
	    fdt32_to_cpu(value[0]) != fdt_get_phandle(fdt, torch[0]) ||
	    fdt32_to_cpu(value[1]) != fdt_get_phandle(fdt, torch[1]))
		return 0;
	for (i = 0; i < 3; i++) {
		int child = fdt_subnode_offset(fdt, rgb, colors[i]);

		if (child < 0 || !uke_light_cell(fdt, child, "led-sources", i))
			return 0;
		value = (const fdt32_t *)fdt_getprop(fdt, child, "pwms", &bytes);
		if (!value || bytes != 12 || !fdt_get_phandle(fdt, pwm) ||
		    fdt32_to_cpu(value[0]) != fdt_get_phandle(fdt, pwm) ||
		    fdt32_to_cpu(value[1]) != i || fdt32_to_cpu(value[2]) != 1000000)
			return 0;
	}
	return 1;
}
#endif
