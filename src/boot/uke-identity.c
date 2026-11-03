// SPDX-License-Identifier: GPL-2.0-only
#include <linux/bootconfig.h>
#include <linux/errno.h>
#include <linux/init.h>
#include <linux/of.h>
#include <linux/string.h>

static int __init uke_identity_init(void)
{
#ifdef CONFIG_BOOT_CONFIG
	struct xbc_node *hardware_node = NULL, *product_node = NULL;
	struct device_node *root;
	const char *hardware, *product;
	static char model[] = "POCO Pad X1";
	static struct property property = {
		.name = "model", .length = sizeof(model), .value = model,
	};
	static struct {
		const char *path;
		struct property property;
	} updates[] = {
#define UKE_IDENTITY(p, n, v) { p, { .name = n, .length = sizeof(v), .value = v } }
		UKE_IDENTITY("/firmware/uke-accessories", "pen-model", "POCO Focus Pen"),
		UKE_IDENTITY("/firmware/uke-accessories", "keyboard-model", "POCO Focus Keyboard"),
		UKE_IDENTITY("/soc/qcom,qupv3_0_geni_se@ac0000/i2c@a8c000/nanosic@4c", "model", "POCO Focus Keyboard"),
		UKE_IDENTITY("/soc/qcom,qupv3_0_geni_se@ac0000/spi@a90000/novatek@0", "label", "POCO Pad X1 Touchscreen"),
		UKE_IDENTITY("/soc/qcom,qupv3_1_geni_se@8c0000/i2c@890000/ntag@57", "status", "okay"),
#undef UKE_IDENTITY
	};
	unsigned int i;
	int ret;

	if (!of_machine_is_compatible("xiaomi,uke") ||
	    !of_machine_is_compatible("qcom,sm7675"))
		return 0;
	hardware = xbc_find_value("androidboot.hardware.sku", &hardware_node);
	product = xbc_find_value("androidboot.product.hardware.sku", &product_node);
	/* Accept only the exact scalar SKU observed in stock and Fedora boot data. */
	if ((!hardware && !product) ||
	    (hardware && (!hardware_node || xbc_node_is_array(hardware_node) ||
			 strcmp(hardware, "ukepgl"))) ||
	    (product && (!product_node || xbc_node_is_array(product_node) ||
			strcmp(product, "ukepgl"))))
		return 0;
	root = of_find_node_by_path("/");
	if (!root)
		return -ENODEV;
	/* OF retains the property, so neither it nor its value may be init data. */
	ret = of_update_property(root, &property);
	of_node_put(root);
	if (ret)
		return ret;
	for (i = 0; i < sizeof(updates) / sizeof(updates[0]); i++) {
		root = of_find_node_by_path(updates[i].path);
		if (!root)
			continue;
		ret = of_update_property(root, &updates[i].property);
		of_node_put(root);
		if (ret)
			return ret;
	}
	return 0;
#else
	return 0;
#endif
}
/* XBC exists until all initcalls finish; update OF before userspace starts. */
arch_initcall(uke_identity_init);
