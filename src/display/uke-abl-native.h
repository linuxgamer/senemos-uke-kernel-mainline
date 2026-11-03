/* SPDX-License-Identifier: GPL-2.0-only */
#ifdef __KERNEL__
#include "uke-hardware.h"
#include "uke-bwmon.h"
#include "uke-cpu-bwmon.h"
#include "uke-memlat.h"
#else
#ifndef ARRAY_SIZE
#define ARRAY_SIZE(array) (sizeof(array) / sizeof((array)[0]))
#endif
#include "../boot/uke-hardware.h"
#include "../boot/uke-bwmon.h"
#include "../boot/uke-cpu-bwmon.h"
#include "../boot/uke-memlat.h"
#endif
struct uke_native_panel {
	const char *selector;
	void *overlay;
	size_t bytes;
};

/* ABL may omit the trailing colon. Match one complete parameter, not a substring. */
static int UKE_INIT uke_native_panel_selected(const void *fdt, const char *selector)
{
	static const char key[] = "msm_drm.dsi_display0=";
	const char *args, *cursor, *selected = NULL;
	size_t length, selected_length = 0;
	int chosen, bytes;

	if (!selector || strncmp(selector, key, sizeof(key) - 1))
		return -FDT_ERR_BADVALUE;
	length = strlen(selector);
	if (length && selector[length - 1] == ':')
		length--;
	chosen = fdt_path_offset(fdt, "/chosen");
	args = (const char *)fdt_getprop(fdt, chosen, "bootargs", &bytes);
	if (!args || bytes <= 0 || args[bytes - 1] ||
	    strlen(args) != (size_t)bytes - 1)
		return -FDT_ERR_BADVALUE;
	for (cursor = args; *cursor;) {
		const char *start;
		size_t token;

		while (*cursor == ' ' || *cursor == '\t')
			cursor++;
		start = cursor;
		while (*cursor && *cursor != ' ' && *cursor != '\t')
			cursor++;
		token = cursor - start;
		if (token < sizeof(key) - 1 || strncmp(start, key, sizeof(key) - 1))
			continue;
		if (selected)
			return -FDT_ERR_BADVALUE;
		selected = start;
		selected_length = token;
	}
	if (!selected)
		return -FDT_ERR_BADVALUE;
	return selected_length >= length && !strncmp(selected, selector, length) &&
		(selected_length == length || selected[length] == ':');
}

/*
 * Give an unlabeled OEM node a phandle and a symbol so overlays can reference it.
 * Adding the phandle shifts later nodes, so /__symbols__ is resolved afterwards.
 */
static int UKE_INIT uke_native_symbol(void *fdt, const char *name, const char *path)
{
	unsigned int phandle;
	int node = fdt_path_offset(fdt, path), symbols, ret;

	if (node < 0)
		return node;
	phandle = fdt_get_phandle(fdt, node);
	if (!phandle) {
		ret = fdt_generate_phandle(fdt, &phandle);
		if (ret)
			return ret;
		ret = fdt_setprop_u32(fdt, node, "phandle", phandle);
		if (ret)
			return ret;
	}
	symbols = fdt_path_offset(fdt, "/__symbols__");
	if (symbols < 0)
		return symbols;
	return fdt_setprop_string(fdt, symbols, name, path);
}

/* Explicit native-display candidate only; called on the private adapted FDT. */
static int UKE_INIT uke_abl_native(void *fdt, void *overlay, size_t bytes,
				 const char *panel_selector)
{
	static const char backlight[] = "/soc/qcom,qupv3_0_geni_se@ac0000/i2c@a80000/ktz8866@11";
	static const char *const bias_paths[] = {
		"/soc/display_gpio_regulator_vsp", "/soc/display_gpio_regulator_vsn"
	};
	static const char *const bias_symbols[] = { "display_panel_vsp", "display_panel_vsn" };
	static const char *const amp_symbols[] = {
		"uke_amp_tl", "uke_amp_tr", "uke_amp_bl", "uke_amp_br"
	};
	char framebuffer[128];
	const char *text;
	int chosen, node, size, ret;
	unsigned int i;

	if (!fdt || !overlay || bytes < sizeof(struct fdt_header) ||
	    fdt_check_full(overlay, bytes) ||
	    fdt_node_check_compatible(fdt, 0, "xiaomi,uke"))
		return -FDT_ERR_BADVALUE;
	chosen = fdt_path_offset(fdt, "/chosen");
	if (uke_native_panel_selected(fdt, panel_selector) != 1)
		return -FDT_ERR_BADVALUE;
	text = (const char *)fdt_getprop(fdt, chosen, "stdout-path", &size);
	if (!text || size <= 0 || size > (int)sizeof(framebuffer) || text[size - 1] ||
	    strncmp(text, "/chosen/framebuffer@", 20))
		return -FDT_ERR_BADVALUE;
	memcpy(framebuffer, text, size);
	node = fdt_path_offset(fdt, framebuffer);
	if (node < 0 || fdt_node_check_compatible(fdt, node, "simple-framebuffer"))
		return -FDT_ERR_BADVALUE;
	node = fdt_path_offset(fdt, backlight);
	if (node < 0 || fdt_node_check_compatible(fdt, node, "xiaomi,uke-ktz8866-primary") ||
	    !fdt_get_phandle(fdt, node))
		return -FDT_ERR_BADVALUE;
	for (i = 0; i < 2; i++) {
		node = fdt_path_offset(fdt, bias_paths[i]);
		if (node < 0 || fdt_node_check_compatible(fdt, node, "regulator-fixed") ||
		    !fdt_get_phandle(fdt, node))
			return -FDT_ERR_BADVALUE;
	}
	node = fdt_path_offset(fdt, "/__symbols__");
	if (node < 0)
		return node;
	ret = fdt_setprop_string(fdt, node, "uke_primary_backlight", backlight);
	if (ret)
		return ret;
	/* ABL preserves the Uke bias providers but drops their OEM symbol names. */
	for (i = 0; i < 2; i++) {
		ret = fdt_setprop_string(fdt, node, bias_symbols[i], bias_paths[i]);
		if (ret)
			return ret;
	}
	/*
	 * The four OEM speaker amplifiers (QUP1 SE3, 0x34-0x37) carry no labels. The
	 * speaker profile references them; other profiles ignore the extra symbols.
	 */
	for (i = 0; i < sizeof(amp_symbols) / sizeof(amp_symbols[0]); i++) {
		char amp[96];

		snprintf(amp, sizeof(amp),
			 "/soc/qcom,qupv3_1_geni_se@8c0000/i2c@88c000/fs19xx_smartpa@%x",
			 0x34 + i);
		node = fdt_path_offset(fdt, amp);
		if (node < 0 || fdt_node_check_compatible(fdt, node, "foursemi,fs16xx"))
			continue;
		/*
		 * The OEM active-high reset-gpio and the overlay's reset-gpios name the
		 * same line; gpiolib then treats it as shared and may refuse to release
		 * the amplifier from reset. Leave only the overlay's property.
		 */
		ret = fdt_delprop(fdt, node, "reset-gpio");
		if (ret && ret != -FDT_ERR_NOTFOUND)
			return ret;
		ret = uke_native_symbol(fdt, amp_symbols[i], amp);
		if (ret)
			return ret;
	}
	ret = fdt_overlay_apply(fdt, overlay);
	if (ret)
		return ret;
	ret = uke_hardware_names(fdt);
	if (ret)
		return ret;
	ret = uke_hardware_simplify(fdt);
	if (ret)
		return ret;
	ret = uke_bwmon_apply(fdt);
	if (ret)
		return ret;
	ret = uke_cpu_bwmon_apply(fdt);
	if (ret)
		return ret;
	ret = uke_memlat_apply(fdt);
	if (ret)
		return ret;
	node = fdt_path_offset(fdt, framebuffer);
	ret = fdt_setprop_string(fdt, node, "status", "okay");
	if (ret)
		return ret;
	/* Firmware scanout must not wait for or blank the native panel backlight. */
	ret = fdt_delprop(fdt, node, "backlight");
	return ret && ret != -FDT_ERR_NOTFOUND ? ret : fdt_pack(fdt);
}

/* Select before either overlay or the inherited board graph is modified. */
static inline int UKE_INIT uke_abl_native_select(void *fdt,
		const struct uke_native_panel *panels, unsigned int count)
{
	unsigned int i;
	int selected;

	if (!fdt || !panels || !count || fdt_check_header(fdt))
		return -FDT_ERR_BADVALUE;
	for (i = 0; i < count; i++) {
		selected = uke_native_panel_selected(fdt, panels[i].selector);
		if (selected < 0)
			return selected;
		if (selected)
			return uke_abl_native(fdt, panels[i].overlay, panels[i].bytes,
					      panels[i].selector);
	}
	return -FDT_ERR_BADVALUE;
}
