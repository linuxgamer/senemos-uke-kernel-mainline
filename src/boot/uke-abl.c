// SPDX-License-Identifier: GPL-2.0-only
/*
 * Stock-ABL development path for Uke. Keep the bootloader's selected FDT,
 * RAM, reservations, selectors and unit data. Apply only the reviewed UFS
 * and USB provider overlays before OF scans or creates platform devices.
 * The display geometry is cross-checked against Uke's OEM O82 panel and
 * the owner's DRM mode inventory. The splash address comes from this boot.
 * This is a simplefb handoff candidate, not a panel or power-management port.
 */
#ifdef __KERNEL__
#include <linux/cache.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/libfdt.h>
#include <linux/sizes.h>
#include <asm/memory.h>
#include <asm/processor.h>
#include "uke-llcc-profile.h"
#define UKE_INIT __init
void *__init uke_abl_prepare_fdt(void *input, int size, phys_addr_t *physical);
void __init uke_abl_prepare_cmdline(const void *fdt, char *cmdline,
				  size_t capacity);
#else
#include <libfdt.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define ARRAY_SIZE(array) (sizeof(array) / sizeof((array)[0]))
#define UKE_INIT
#endif

#define UKE_FDT_CAPACITY (2 * 1024 * 1024)
#define UKE_FB_WIDTH 3200
#define UKE_FB_HEIGHT 2136
#define UKE_FB_STRIDE (UKE_FB_WIDTH * 4)
#define UKE_FB_BYTES (UKE_FB_STRIDE * UKE_FB_HEIGHT)
/* Nominal active dimensions from the 11.2-inch, 3200x2136 panel specification. */
#define UKE_PANEL_WIDTH_MM 237U
#define UKE_PANEL_HEIGHT_MM 158U

#if defined(UKE_LLCC_NATIVE_PROFILE) && UKE_LLCC_NATIVE_PROFILE
#include "uke-llcc.h"
#endif

#ifdef __KERNEL__
#include "uke-root-selector.h"
#endif

#include "uke-ufs.h"

static int UKE_INIT uke_path_reg(const void *fdt, const char *path,
				unsigned int address, unsigned int bytes)
{
	int node = fdt_path_offset(fdt, path), length;
	const fdt32_t *reg;

	if (node < 0)
		return -FDT_ERR_NOTFOUND;
	reg = fdt_getprop(fdt, node, "reg", &length);
	if (!reg || length < 8 || fdt32_to_cpu(reg[0]) != address ||
	    fdt32_to_cpu(reg[1]) != bytes)
		return -FDT_ERR_BADVALUE;
	return 0;
}

static int UKE_INIT uke_delete_optional(void *fdt, const char *path,
				      const char *property)
{
	int node = fdt_path_offset(fdt, path), ret;

	if (node < 0)
		return node;
	ret = fdt_delprop(fdt, node, property);
	return ret == -FDT_ERR_NOTFOUND ? 0 : ret;
}

static int UKE_INIT uke_volume_down_wake(void *fdt)
{
	int node = fdt_path_offset(fdt,
		"/soc/qcom,spmi@c42d000/qcom,pmk8550@0/pon_hlos@1300/resin"), size;
	const fdt32_t *value;

	if (node < 0 || fdt_node_check_compatible(fdt, node, "qcom,pmk8350-resin"))
		return -FDT_ERR_BADVALUE;
	value = fdt_getprop(fdt, node, "linux,code", &size);
	if (!value || size != 4 || fdt32_to_cpu(*value) != 114)
		return -FDT_ERR_BADVALUE;
	value = fdt_getprop(fdt, node, "interrupts", &size);
	if (!value || size != 16 || fdt32_to_cpu(value[0]) != 0 ||
	    fdt32_to_cpu(value[1]) != 0x13 || fdt32_to_cpu(value[2]) != 6 ||
	    fdt32_to_cpu(value[3]) != 3)
		return -FDT_ERR_BADVALUE;
	/* The existing PMIC driver owns IRQ wake; retain its key/reset contract. */
	return fdt_setprop(fdt, node, "wakeup-source", NULL, 0);
}

static int UKE_INIT uke_legacy_va_gpio_flag(void *fdt)
{
	int node = fdt_path_offset(fdt, "/soc/spf_core_platform/lpass-cdc/va-macro@6D44000");
	const fdt32_t *value;
	int size;

	if (node < 0 || fdt_node_check_compatible(fdt, node, "qcom,lpass-cdc-va-macro"))
		return 0;
	value = fdt_getprop(fdt, node, "qcom,is-used-swr-gpio", &size);
	if (!value || size != 4 || fdt32_to_cpu(*value) != 1)
		return 0;
	/* Unused legacy scalar flag is otherwise parsed as a GPIO phandle. */
	return fdt_delprop(fdt, node, "qcom,is-used-swr-gpio");
}

static int UKE_INIT uke_empty_spmi_bus(void *fdt)
{
	static const unsigned int expected[] = {
		0xc432000, 0x4000, 0xc400000, 0x3000, 0xc500000, 0x400000,
		0xc440000, 0x80000, 0xc4d0000, 0x10000,
	};
	int node = fdt_path_offset(fdt, "/soc/qcom,spmi@c432000"), size, child;
	const fdt32_t *reg, *bus;
	unsigned int i;

	if (node < 0 || fdt_node_check_compatible(fdt, node, "qcom,spmi-pmic-arb"))
		return 0;
	reg = fdt_getprop(fdt, node, "reg", &size);
	if (!reg || size != (int)sizeof(expected))
		return 0;
	for (i = 0; i < ARRAY_SIZE(expected); i++)
		if (fdt32_to_cpu(reg[i]) != expected[i])
			return 0;
	bus = fdt_getprop(fdt, node, "qcom,bus-id", &size);
	if (!bus || size != 4 || fdt32_to_cpu(*bus) != 1)
		return 0;
	child = fdt_first_subnode(fdt, node);
	if (child != -FDT_ERR_NOTFOUND)
		return child < 0 ? child : 0;
	/* This selected OEM bus has no children and shares the active arbiter. */
	return fdt_setprop_string(fdt, node, "status", "disabled");
}

static int UKE_INIT uke_empty_demura_regions(void *fdt)
{
	static const char * const paths[] = {
		"/reserved-memory/demura_region_0",
		"/reserved-memory/demura_region_1",
	};
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(paths); i++) {
		int node = fdt_path_offset(fdt, paths[i]), size, ret;
		const fdt32_t *reg;

		if (node < 0 || fdt_first_subnode(fdt, node) != -FDT_ERR_NOTFOUND ||
		    fdt_getprop(fdt, node, "compatible", NULL) ||
		    fdt_getprop(fdt, node, "size", NULL))
			continue;
		reg = fdt_getprop(fdt, node, "reg", &size);
		if (!reg || size != 16 || reg[0] || reg[1] || reg[2] || reg[3])
			continue;
		/* OEM placeholders are unused only while their address and size are zero. */
		ret = fdt_setprop_string(fdt, node, "status", "disabled");
		if (ret)
			return ret;
	}
	return 0;
}

#include "uke-pmic-adc.h"
#include "uke-cpu-thermal.h"
#include "uke-clock-debug.h"
#include "uke-hall.h"

static int UKE_INIT uke_reboot_cell(const void *fdt)
{
	int node = fdt_path_offset(fdt, "/soc/reboot_reason"), size, parent;
	int cell = fdt_path_offset(fdt, "/soc/qcom,spmi@c42d000/"
				  "qcom,pmk8550@0/sdam@7100/restart@48");
	const fdt32_t *value;

	if (node < 0 || cell < 0 ||
	    fdt_node_check_compatible(fdt, node, "qcom,reboot-reason"))
		return -FDT_ERR_BADVALUE;
	value = fdt_getprop(fdt, node, "nvmem-cells", &size);
	if (!value || size != 4 ||
	    fdt_node_offset_by_phandle(fdt, fdt32_to_cpu(*value)) != cell ||
	    uke_path_reg(fdt, "/soc/qcom,spmi@c42d000/"
			 "qcom,pmk8550@0/sdam@7100/restart@48", 0x48, 1))
		return -FDT_ERR_BADVALUE;
	value = fdt_getprop(fdt, cell, "bits", &size);
	if (!value || size != 8 || fdt32_to_cpu(value[0]) != 1 ||
	    fdt32_to_cpu(value[1]) != 7)
		return -FDT_ERR_BADVALUE;
	parent = fdt_parent_offset(fdt, cell);
	value = fdt_getprop(fdt, parent, "reg", &size);
	if (!value || size != 4 || fdt32_to_cpu(*value) != 0x7100 ||
	    fdt_node_check_compatible(fdt, parent, "qcom,spmi-sdam"))
		return -FDT_ERR_BADVALUE;
	return 0;
}

static int UKE_INIT uke_gpu_opps(const void *fdt)
{
	static const unsigned int points[][3] = {
		{255000000, 56, 2136718}, {353000000, 64, 6074218},
		{500000000, 128, 6671875}, {633000000, 192, 12449218},
		{684000000, 224, 12449218}, {736000000, 256, 12449218},
		{835000000, 320, 14398437}, {900000000, 384, 16500000},
		{950000000, 400, 16500000},
	};
	int gpu = fdt_path_offset(fdt, "/soc/qcom,kgsl-3d0@3d00000");
	int table = fdt_subnode_offset(fdt, gpu, "qcom,gpu-pwrlevels");
	int bytes, child;
	unsigned int i, found = 0;
	const fdt32_t *bandwidth = fdt_getprop(fdt, gpu, "qcom,bus-table-ddr", &bytes);

	if (table < 0 || !bandwidth || bytes <= 0 || bytes % 4)
		return -FDT_ERR_BADVALUE;
	fdt_for_each_subnode(child, fdt, table) {
		int size;
		const fdt32_t *frequency = fdt_getprop(fdt, child, "qcom,gpu-freq", &size);
		if (!frequency || size != 4)
			return -FDT_ERR_BADVALUE;
		for (i = 0; i < sizeof(points) / sizeof(points[0]); i++) {
			const fdt32_t *level, *bus;
			unsigned int index;
			if (fdt32_to_cpu(*frequency) != points[i][0])
				continue;
			if (found & (1U << i))
				return -FDT_ERR_BADVALUE;
			level = fdt_getprop(fdt, child, "qcom,level", &size);
			if (!level || size != 4 || fdt32_to_cpu(*level) != points[i][1])
				return -FDT_ERR_BADVALUE;
			bus = fdt_getprop(fdt, child, "qcom,bus-freq", &size);
			if (!bus || size != 4)
				return -FDT_ERR_BADVALUE;
			index = fdt32_to_cpu(*bus);
			if (index >= (unsigned int)bytes / 4 || fdt32_to_cpu(bandwidth[index]) != points[i][2])
				return -FDT_ERR_BADVALUE;
			found |= 1U << i;
		}
	}
	return found == 0x1ff ? 0 : -FDT_ERR_BADVALUE;
}

static int UKE_INIT uke_legacy_layout(const void *fdt)
{
	static const struct {
		const char *path, *property;
		unsigned int count, values[14];
	} expected[] = {
		{ "/soc", "#address-cells", 1, { 1 } },
		{ "/soc", "#size-cells", 1, { 1 } },
		{ "/soc/qcom,kgsl-3d0@3d00000", "qcom,chipid", 1, { 0x43030b00 } },
		{ "/soc/qcom,kgsl-3d0@3d00000", "reg", 14, { 0x3d00000, 0x40000, 0x3d50000, 0x10000, 0x3d61000, 0x800, 0x3d9e000, 0x1000, 0x10048000, 0x8000, 0x10900000, 0x80000, 0x10b05000, 0x1000 } },
		{ "/soc/qcom,kgsl-3d0@3d00000", "interrupts", 3, { 0, 300, 4 } },
		{ "/soc/qcom,gmu@3d69000", "reg", 6, { 0x3d68000, 0x37000, 0xb280000, 0x10000, 0x3d40000, 0x10000 } },
		{ "/soc/qcom,gmu@3d69000", "interrupts", 6, { 0, 304, 4, 0, 305, 4 } },
		{ "/soc/clock-controller@3d90000", "reg", 2, { 0x3d90000, 0xa000 } },
		{ "/soc/kgsl-smmu@3da0000", "reg", 4, { 0x3da0000, 0x40000, 0x3de6000, 0x40 } },
		{ "/soc/qcom,gdsc@3d99108", "reg", 2, { 0x3d9908c, 4 } },
		{ "/soc/qcom,gdsc@3d9905c", "reg", 2, { 0x3d99034, 4 } },
		{ "/soc/syscon@3d99504", "reg", 2, { 0x3d99504, 4 } },
		{ "/soc/mmio-sram@17D09400", "#address-cells", 1, { 2 } },
		{ "/soc/mmio-sram@17D09400", "#size-cells", 1, { 2 } },
		{ "/soc/mmio-sram@17D09400", "reg", 4, { 0, 0x17d09400, 0, 0x400 } },
		{ "/soc/mmio-sram@17D09400", "ranges", 6, { 0, 0, 0, 0x17d09400, 0, 0x400 } },
		{ "/soc/mmio-sram@17D09400/scmi-shmem@0", "reg", 4, { 0, 0x17d09400, 0, 0x400 } },
		{ "/soc/qcom,spmi@c42d000/qcom,pmk8550@0/sdam@7000", "reg", 1, { 0x7000 } },
		{ "/soc/qcom,spmi@c42d000/qcom,pmk8550@0/sdam@7000/smb1510_present@5d", "reg", 2, { 0x5d, 1 } },
		{ "/soc/qcom,spmi@c42d000/qcom,pmk8550@0/sdam@7000/smb1510_present@5d", "bits", 2, { 5, 5 } },
		{ "/soc/qcom,spmi@c42d000/qcom,pmk8550@0/sdam@7000/ufs_dev@ad", "reg", 2, { 0xaf, 1 } },
		{ "/soc/qcom,spmi@c42d000/qcom,pmk8550@0/sdam@7000/ufs_dev@ad", "bits", 2, { 0, 0 } },
	};
	unsigned int i, j;
	int node, size;
	const fdt32_t *value;

	for (i = 0; i < sizeof(expected) / sizeof(expected[0]); i++) {
		node = fdt_path_offset(fdt, expected[i].path);
		if (node < 0)
			return node;
		value = fdt_getprop(fdt, node, expected[i].property, &size);
		if (!value || size != (int)(expected[i].count * sizeof(*value)))
			return -FDT_ERR_BADVALUE;
		for (j = 0; j < expected[i].count; j++)
			if (fdt32_to_cpu(value[j]) != expected[i].values[j])
				return -FDT_ERR_BADVALUE;
	}
	if (fdt_node_check_compatible(fdt, fdt_path_offset(fdt, "/soc/mmio-sram@17D09400"), "mmio-sram") ||
	    fdt_node_check_compatible(fdt, fdt_path_offset(fdt, "/soc/mmio-sram@17D09400/scmi-shmem@0"), "arm,scmi-shmem") ||
	    fdt_node_check_compatible(fdt, fdt_path_offset(fdt, "/soc/qcom,spmi@c42d000/qcom,pmk8550@0/sdam@7000"), "qcom,spmi-sdam"))
		return -FDT_ERR_BADVALUE;
	return 0;
}

static int UKE_INIT uke_scope_smmu_clients(void *fdt)
{
	static const char * const paths[] = {
		"/soc/ufshc@1d84000", "/soc/ssusb@a600000",
		"/soc/qcom,gpi-dma@a00000",
		"/soc/qcom,qupv3_0_geni_se@ac0000",
		"/soc/qcom,qupv3_1_geni_se@8c0000",
		"/soc/qcom,gpi-dma@800000",
		"/soc/qcom,wcn6750",
	};
	static const unsigned int sids[] = { 0x60, 0x40, 0xb6, 0xa3, 0x423, 0x436, 0x1400 };
	static const unsigned int masks[] = { 0, 0, 0, 0, 0, 0, 1 };
	int smmu = fdt_path_offset(fdt, "/soc/apps-smmu@15000000");
	unsigned int phandle;
	int node, size, ret;
	unsigned int i;

	if (smmu < 0 || !(phandle = fdt_get_phandle(fdt, smmu)))
		return -FDT_ERR_BADPHANDLE;
	for (i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
		const fdt32_t *spec;

		node = fdt_path_offset(fdt, paths[i]);
		if (node < 0)
			return node;
		spec = fdt_getprop(fdt, node, "iommus", &size);
		if (!spec || size != 12 || fdt32_to_cpu(spec[0]) != phandle ||
		    fdt32_to_cpu(spec[1]) != sids[i] || fdt32_to_cpu(spec[2]) != masks[i])
			return -FDT_ERR_BADVALUE;
	}
	for (node = fdt_next_node(fdt, -1, NULL); node >= 0;
	     node = fdt_next_node(fdt, node, NULL)) {
		const fdt32_t *spec = fdt_getprop(fdt, node, "iommus", &size);
		int pos = 0, total, scoped = 0, admitted = 0;

		if (!spec)
			continue;
		if (size <= 0 || size % sizeof(*spec))
			return -FDT_ERR_BADVALUE;
		total = size / (int)sizeof(*spec);
		while (pos < total) {
			const fdt32_t *cells;
			unsigned int count, provider = fdt32_to_cpu(spec[pos++]);
			int length, offset = fdt_node_offset_by_phandle(fdt, provider);

			if (offset < 0)
				return offset;
			cells = fdt_getprop(fdt, offset, "#iommu-cells", &length);
			if (!cells || length != 4)
				return -FDT_ERR_BADVALUE;
			count = fdt32_to_cpu(*cells);
			if (count > (unsigned int)(total - pos))
				return -FDT_ERR_BADVALUE;
			if (provider == phandle)
				scoped = 1;
			pos += count;
		}
		if (!scoped)
			continue;
		for (i = 0; i < sizeof(paths) / sizeof(paths[0]); i++)
			if (node == fdt_path_offset(fdt, paths[i]))
				admitted = 1;
		/* Disabled clients cannot reclaim firmware display streams or DMA
		 * through this provider outside its seven reviewed consumers.
		 */
		if (!admitted) {
			ret = fdt_setprop_string(fdt, node, "status", "disabled");
			if (ret)
				return ret;
		}
	}
	return node == -FDT_ERR_NOTFOUND ? 0 : node;
}

static int UKE_INIT uke_sensor_fastrpc(void *fdt)
{
	static const char * const source[] = {
		"/soc/qcom,msm_fastrpc/qcom,msm_fastrpc_compute_cb10",
		"/soc/qcom,msm_fastrpc/qcom,msm_fastrpc_compute_cb12",
	};
	static const char * const names[] = { "compute-cb@3", "compute-cb@5" };
	static const unsigned int ids[] = { 3, 5 }, pd[] = { 1, 2 };
	const char *path = "/soc/remoteproc-adsp@03000000/glink-edge/qcom,msm_fastrpc_rpmsg";
	fdt32_t maps[2][6];
	int smmu = fdt_path_offset(fdt, "/soc/apps-smmu@15000000");
	unsigned int phandle = smmu < 0 ? 0 : fdt_get_phandle(fdt, smmu);
	int node, length, ret, i;
	const fdt32_t *value;
	const char *label;

	if (!phandle)
		return -FDT_ERR_BADPHANDLE;
	node = fdt_path_offset(fdt, path);
	if (node < 0 || fdt_node_check_compatible(fdt, node, "qcom,msm-fastrpc-rpmsg"))
		return -FDT_ERR_BADVALUE;
	label = fdt_getprop(fdt, node, "qcom,glink-channels", &length);
	if (!label || length != sizeof("fastrpcglink-apps-dsp") ||
	    memcmp(label, "fastrpcglink-apps-dsp", length))
		return -FDT_ERR_BADVALUE;
	for (i = 0; i < 2; i++) {
		node = fdt_path_offset(fdt, source[i]);
		if (node < 0 || fdt_node_check_compatible(fdt, node, "qcom,msm-fastrpc-compute-cb"))
			return -FDT_ERR_BADVALUE;
		label = fdt_getprop(fdt, node, "label", &length);
		if (!label || length != sizeof("adsprpc-smd") || memcmp(label, "adsprpc-smd", length))
			return -FDT_ERR_BADVALUE;
		value = fdt_getprop(fdt, node, "pd-type", &length);
		if (!value || length != 4 || fdt32_to_cpu(*value) != pd[i])
			return -FDT_ERR_BADVALUE;
		value = fdt_getprop(fdt, node, "iommus", &length);
		if (!value || length != sizeof(maps[i]) ||
		    fdt32_to_cpu(value[0]) != phandle || fdt32_to_cpu(value[3]) != phandle ||
		    fdt32_to_cpu(value[1]) != 0x1000 + ids[i] || fdt32_to_cpu(value[2]) != 0x80 ||
		    fdt32_to_cpu(value[4]) != 0x1040 + ids[i] || fdt32_to_cpu(value[5]) != 0x20)
			return -FDT_ERR_BADVALUE;
		memcpy(maps[i], value, sizeof(maps[i]));
		if (!fdt_getprop(fdt, node, "dma-coherent", &length) || length ||
		    fdt_getprop(fdt, node, "qcom,secure-context-bank", NULL))
			return -FDT_ERR_BADVALUE;
	}
	/* Keep OEM context banks disabled; only the root/sensor maps are copied.
	 * No remote heap, VMID reassignment, CDSP or audio context is admitted.
	 */
	node = fdt_path_offset(fdt, path);
	ret = fdt_setprop_string(fdt, node, "compatible", "qcom,fastrpc");
	if (ret)
		return ret;
	ret = fdt_setprop_string(fdt, node, "label", "adsp");
	if (ret)
		return ret;
	ret = fdt_setprop(fdt, node, "qcom,non-secure-domain", NULL, 0);
	if (ret)
		return ret;
	ret = fdt_setprop_u32(fdt, node, "#address-cells", 1);
	if (ret)
		return ret;
	ret = fdt_setprop_u32(fdt, node, "#size-cells", 0);
	if (ret)
		return ret;
	ret = fdt_delprop(fdt, node, "qcom,intents");
	if (ret && ret != -FDT_ERR_NOTFOUND)
		return ret;
	for (i = 1; i >= 0; i--) {
		node = fdt_add_subnode(fdt, fdt_path_offset(fdt, path), names[i]);
		if (node < 0)
			return node;
		ret = fdt_setprop_string(fdt, node, "compatible", "qcom,fastrpc-compute-cb");
		if (ret)
			return ret;
		ret = fdt_setprop_u32(fdt, node, "reg", ids[i]);
		if (ret)
			return ret;
		ret = fdt_setprop(fdt, node, "iommus", maps[i], sizeof(maps[i]));
		if (ret)
			return ret;
		ret = fdt_setprop(fdt, node, "dma-coherent", NULL, 0);
		if (ret)
			return ret;
	}
	return 0;
}

static int UKE_INIT uke_backlight_bus(const void *fdt)
{
	const char *bus = "/soc/qcom,qupv3_1_geni_se@8c0000/i2c@890000";
	int node = fdt_path_offset(fdt, bus), size, i;
	int dma = fdt_path_offset(fdt, "/soc/qcom,gpi-dma@800000");
	int ktz = fdt_path_offset(fdt, "/soc/qcom,qupv3_1_geni_se@8c0000/i2c@890000/ktz8866@11");
	const fdt32_t *value;
	unsigned int phandle;
	static const unsigned int route[] = { 0, 4, 3, 64, 0, 1, 4, 3, 64, 0 };
	static const char * const dma_props[] = {
		"#dma-cells", "qcom,max-num-gpii", "qcom,gpii-mask", "qcom,gpi-ee-offset",
	};
	static const unsigned int dma_values[] = { 5, 12, 0x1e, 0x10000 };

	if (node < 0 || dma < 0 || ktz < 0 || !(phandle = fdt_get_phandle(fdt, dma)) ||
	    fdt_node_check_compatible(fdt, node, "qcom,i2c-geni") ||
	    fdt_node_check_compatible(fdt, dma, "qcom,gpi-dma") ||
	    fdt_node_check_compatible(fdt, ktz, "ktz,ktz8866") ||
	    uke_path_reg(fdt, bus, 0x890000, 0x4000) ||
	    uke_path_reg(fdt, "/soc/qcom,qupv3_1_geni_se@8c0000", 0x8c0000, 0x2000) ||
	    uke_path_reg(fdt, "/soc/qcom,gpi-dma@800000", 0x800000, 0x60000))
		return -FDT_ERR_BADVALUE;
	value = fdt_getprop(fdt, ktz, "reg", &size);
	if (!value || size != 4 || fdt32_to_cpu(*value) != 0x11)
		return -FDT_ERR_BADVALUE;
	ktz = fdt_path_offset(fdt, "/soc/qcom,qupv3_0_geni_se@ac0000/i2c@a80000/ktz8866@11");
	if (ktz < 0 || fdt_node_check_compatible(fdt, ktz, "ktz,ktz8866"))
		return -FDT_ERR_BADVALUE;
	value = fdt_getprop(fdt, ktz, "reg", &size);
	if (!value || size != 4 || fdt32_to_cpu(*value) != 0x11)
		return -FDT_ERR_BADVALUE;
	for (i = 0; i < 4; i++) {
		value = fdt_getprop(fdt, dma, dma_props[i], &size);
		if (!value || size != 4 || fdt32_to_cpu(*value) != dma_values[i])
			return -FDT_ERR_BADVALUE;
	}
	value = fdt_getprop(fdt, node, "dmas", &size);
	if (!value || size != (int)(12 * sizeof(*value)))
		return -FDT_ERR_BADVALUE;
	for (i = 0; i < 2; i++) {
		int j;
		if (fdt32_to_cpu(value[i * 6]) != phandle)
			return -FDT_ERR_BADVALUE;
		for (j = 0; j < 5; j++)
			if (fdt32_to_cpu(value[i * 6 + j + 1]) != route[i * 5 + j])
				return -FDT_ERR_BADVALUE;
	}
	value = fdt_getprop(fdt, node, "qcom,clk-freq-out", &size);
	if (!value || size != 4 || fdt32_to_cpu(*value) != 400000)
		return -FDT_ERR_BADVALUE;
	return 0;
}

static int UKE_INIT uke_scope_qup_buses(void *fdt)
{
	static const char * const parents[] = {
		"/soc/qcom,qupv3_1_geni_se@8c0000",
		"/soc/qcom,qupv3_1_geni_se@8c0000/i2c@890000",
		"/soc/qcom,qupv3_0_geni_se@ac0000",
	};
	static const char * const admitted[][4] = {
		{ "i2c@890000", NULL, NULL, NULL },
		{ "ktz8866@11", "ntag@57", NULL, NULL },
		{ "i2c@a80000", "spi@a90000", "spi@a84000", NULL },
	};
	int i, j, parent, child, ret;

	/* Other OEM serial engines retain five-cell vendor DMA routes. */
	for (i = 0; i < 3; i++) {
		parent = fdt_path_offset(fdt, parents[i]);
		if (parent < 0)
			return parent;
		fdt_for_each_subnode(child, fdt, parent) {
			for (j = 0; admitted[i][j]; j++)
				if (!strcmp(fdt_get_name(fdt, child, NULL), admitted[i][j]))
					break;
			if (admitted[i][j])
				continue;
			ret = fdt_setprop_string(fdt, child, "status", "disabled");
			if (ret)
				return ret;
		}
		if (child != -FDT_ERR_NOTFOUND)
			return child;
	}
	return 0;
}

static int UKE_INIT uke_pair_backlights(void *fdt)
{
	const char *secondary = "/soc/qcom,qupv3_1_geni_se@8c0000/i2c@890000/ktz8866@11";
	const char *primary = "/soc/qcom,qupv3_0_geni_se@ac0000/i2c@a80000/ktz8866@11";
	int node = fdt_path_offset(fdt, secondary), ret;
	unsigned int phandle;

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
	ret = fdt_setprop_string(fdt, node, "compatible", "xiaomi,uke-ktz8866-secondary");
	if (ret)
		return ret;
	node = fdt_path_offset(fdt, primary);
	if (node < 0)
		return node;
	ret = fdt_setprop_string(fdt, node, "compatible", "xiaomi,uke-ktz8866-primary");
	if (ret)
		return ret;
	return fdt_setprop_u32(fdt, node, "xiaomi,secondary", phandle);
}

static int UKE_INIT uke_wifi_graph(const void *fdt)
{
	static const char * const supplies[] = { "vdd-cx-mx-supply", "vdd-1.8-xo-supply", "vdd-1.3-rfa-supply" };
	static const char * const resources[] = { "smpb3", "smpb1", "smpb2" };
	static const unsigned int initial_uv[] = { 984000, 1856000, 1256000 };
	int wifi = fdt_path_offset(fdt, "/soc/qcom,wcn6750");
	int wpss = fdt_path_offset(fdt, "/soc/remoteproc-wpss@9bb00000");
	int msa = fdt_path_offset(fdt, "/reserved-memory/wlan_msa_region@a6400000");
	const fdt32_t *cells;
	int size, i, target, parent;

	if (wifi < 0 || wpss < 0 || msa < 0 ||
	    fdt_node_check_compatible(fdt, wifi, "qcom,wcn6750") ||
	    fdt_node_check_compatible(fdt, wpss, "qcom,cliffs-wpss-pas") ||
	    uke_path_reg(fdt, "/soc/remoteproc-wpss@9bb00000", 0x9bb00000, 0x10000))
		return -FDT_ERR_BADVALUE;
	cells = fdt_getprop(fdt, wifi, "qcom,rproc-handle", &size);
	if (!cells || size != 4 || fdt_node_offset_by_phandle(fdt, fdt32_to_cpu(*cells)) != wpss)
		return -FDT_ERR_BADPHANDLE;
	cells = fdt_getprop(fdt, wifi, "qcom,wlan-msa-fixed-region", &size);
	if (!cells || size != 4 || fdt_node_offset_by_phandle(fdt, fdt32_to_cpu(*cells)) != msa)
		return -FDT_ERR_BADPHANDLE;
	cells = fdt_getprop(fdt, msa, "reg", &size);
	if (!cells || size != 16 || fdt32_to_cpu(cells[0]) ||
	    fdt32_to_cpu(cells[1]) != 0xa6400000 || fdt32_to_cpu(cells[2]) ||
	    fdt32_to_cpu(cells[3]) != 0xc00000 || !fdt_getprop(fdt, msa, "no-map", NULL))
		return -FDT_ERR_BADVALUE;
	cells = fdt_getprop(fdt, wifi, "reg", &size);
	if (!cells || size != 16 || fdt32_to_cpu(cells[0]) != 0x17110040 ||
	    fdt32_to_cpu(cells[1]) || fdt32_to_cpu(cells[2]) != 0xc0000000 ||
	    fdt32_to_cpu(cells[3]) != 0x10000)
		return -FDT_ERR_BADVALUE;
	cells = fdt_getprop(fdt, wifi, "interrupts", &size);
	if (!cells || size != 32 * 3 * 4)
		return -FDT_ERR_BADVALUE;
	for (i = 0; i < 32; i++)
		if (fdt32_to_cpu(cells[i * 3]) || fdt32_to_cpu(cells[i * 3 + 1]) != 768U + (unsigned int)i ||
		    fdt32_to_cpu(cells[i * 3 + 2]) != 1)
			return -FDT_ERR_BADVALUE;
	for (i = 0; i < 3; i++) {
		const char *resource;

		cells = fdt_getprop(fdt, wifi, supplies[i], &size);
		if (!cells || size != 4)
			return -FDT_ERR_BADPHANDLE;
		target = fdt_node_offset_by_phandle(fdt, fdt32_to_cpu(*cells));
		parent = fdt_parent_offset(fdt, target);
		resource = fdt_getprop(fdt, parent, "qcom,resource-name", &size);
		if (!resource || size != (int)strlen(resources[i]) + 1 ||
		    strcmp(resource, resources[i]))
			return -FDT_ERR_BADVALUE;
		cells = fdt_getprop(fdt, target, "qcom,init-voltage", &size);
		if (!cells || size != 4 || fdt32_to_cpu(*cells) != initial_uv[i])
			return -FDT_ERR_BADVALUE;
	}
	return 0;
}

static int UKE_INIT uke_spi_graph(const void *fdt)
{
	const char *path = "/soc/qcom,qupv3_0_geni_se@ac0000/spi@a90000";
	int node = fdt_path_offset(fdt, path), size, i;
	int gcc = fdt_path_offset(fdt, "/soc/clock-controller@100000");
	int gpi = fdt_path_offset(fdt, "/soc/qcom,gpi-dma@a00000");
	const fdt32_t *cells;
	static const unsigned int dma[] = { 0, 4, 1, 64, 2, 1, 4, 1, 64, 2 };

	if (node < 0 || gcc < 0 || gpi < 0 ||
	    uke_path_reg(fdt, path, 0xa90000, 0x4000) ||
	    fdt_node_check_compatible(fdt, node, "qcom,spi-geni"))
		return -FDT_ERR_BADVALUE;
	cells = fdt_getprop(fdt, node, "clocks", &size);
	if (!cells || size != 8 || fdt32_to_cpu(cells[0]) != fdt_get_phandle(fdt, gcc) ||
	    fdt32_to_cpu(cells[1]) != 73)
		return -FDT_ERR_BADVALUE;
	cells = fdt_getprop(fdt, node, "interrupts", &size);
	if (!cells || size != 12 || fdt32_to_cpu(cells[0]) ||
	    fdt32_to_cpu(cells[1]) != 357 || fdt32_to_cpu(cells[2]) != 4)
		return -FDT_ERR_BADVALUE;
	cells = fdt_getprop(fdt, node, "dmas", &size);
	if (!cells || size != 48 || fdt32_to_cpu(cells[0]) != fdt_get_phandle(fdt, gpi) ||
	    fdt32_to_cpu(cells[6]) != fdt_get_phandle(fdt, gpi))
		return -FDT_ERR_BADVALUE;
	for (i = 0; i < 10; i++)
		if (fdt32_to_cpu(cells[i < 5 ? i + 1 : i + 2]) != dma[i])
			return -FDT_ERR_BADVALUE;
	node = fdt_path_offset(fdt, "/soc/qcom,qupv3_0_geni_se@ac0000/spi@a90000/novatek@0");
	if (node < 0 || fdt_node_check_compatible(fdt, node, "novatek,NVT-ts-spi"))
		return -FDT_ERR_BADVALUE;
	cells = fdt_getprop(fdt, node, "reg", &size);
	if (!cells || size != 4 || fdt32_to_cpu(*cells))
		return -FDT_ERR_BADVALUE;
	cells = fdt_getprop(fdt, node, "spi-max-frequency", &size);
	if (!cells || size != 4 || fdt32_to_cpu(*cells) != 19200000)
		return -FDT_ERR_BADVALUE;
	if (fdt_stringlist_count(fdt, node, "pinctrl-names") != 2 ||
	    strcmp(fdt_stringlist_get(fdt, node, "pinctrl-names", 0, NULL), "pmx_ts_active") ||
	    strcmp(fdt_stringlist_get(fdt, node, "pinctrl-names", 1, NULL), "pmx_ts_suspend"))
		return -FDT_ERR_BADVALUE;
	for (i = 0; i < 2; i++) {
		const char *name = i ? "mi_ts_spi_cs_suspend" : "mi_ts_spi_cs_active";
		const char *value;
		int state, mux, config;

		cells = fdt_getprop(fdt, node, i ? "pinctrl-1" : "pinctrl-0", &size);
		if (!cells || size != 4 ||
		    (state = fdt_node_offset_by_phandle(fdt, fdt32_to_cpu(*cells))) < 0 ||
		    strcmp(fdt_get_name(fdt, state, NULL), name))
			return -FDT_ERR_BADPHANDLE;
		mux = fdt_subnode_offset(fdt, state, "mux");
		config = fdt_subnode_offset(fdt, state, "config");
		value = fdt_getprop(fdt, mux, "pins", &size);
		if (!value || size != (int)sizeof("gpio19") || strcmp(value, "gpio19"))
			return -FDT_ERR_BADVALUE;
		value = fdt_getprop(fdt, mux, "function", &size);
		name = i ? "gpio" : "qup0_se4_l3";
		if (!value || size != (int)strlen(name) + 1 || strcmp(value, name))
			return -FDT_ERR_BADVALUE;
		value = fdt_getprop(fdt, config, "pins", &size);
		if (!value || size != (int)sizeof("gpio19") || strcmp(value, "gpio19"))
			return -FDT_ERR_BADVALUE;
		cells = fdt_getprop(fdt, config, "drive-strength", &size);
		if (!cells || size != 4 || fdt32_to_cpu(*cells) != (i ? 2U : 6U) ||
		    !fdt_getprop(fdt, config, i ? "bias-pull-down" : "bias-disable", NULL) ||
		    (i && !fdt_getprop(fdt, config, "output-low", NULL)))
			return -FDT_ERR_BADVALUE;
	}
	cells = fdt_getprop(fdt, node, "panel", &size);
	if (!cells || size != 8)
		return -FDT_ERR_BADPHANDLE;
	for (i = 0; i < 2; i++) {
		static const char * const names[] = {
			"qcom,mdss_dsi_o82_42_02_0b_dualdsi_dsc_vid",
			"qcom,mdss_dsi_o82_36_02_0a_dualdsi_dsc_vid",
		};
		int panel = fdt_node_offset_by_phandle(fdt, fdt32_to_cpu(cells[i]));

		if (panel < 0 || strcmp(fdt_get_name(fdt, panel, NULL), names[i]))
			return -FDT_ERR_BADPHANDLE;
	}
	node = fdt_path_offset(fdt, "/soc/qcom,qupv3_0_geni_se@ac0000/spi@a90000/goodix-berlin@0");
	if (node < 0 || fdt_getprop(fdt, node, "compatible", NULL) ||
	    fdt_getprop(fdt, node, "reg", NULL))
		return -FDT_ERR_BADVALUE;
	return 0;
}

static int UKE_INIT uke_board_pins(const void *fdt)
{
	static const char tlmm_path[] = "/soc/pinctrl@f000000";
#define UKE_QUP0 "/soc/qcom,qupv3_0_geni_se@ac0000/"
#define UKE_QUP1 "/soc/qcom,qupv3_1_geni_se@8c0000/"
#define UKE_ROUTE(bus, prop, slot, count, pin, mux, drive) \
	{ bus, prop, slot, count, pin, sizeof(pin), mux, drive }
	static const struct {
		const char *bus, *property;
		unsigned int slot, count;
		const char *pins;
		unsigned int pin_bytes;
		const char *function;
		unsigned int drive;
	} routes[] = {
		UKE_ROUTE(UKE_QUP0 "i2c@a80000", "pinctrl-0", 0, 2, "gpio52", "qup0_se0_l0", 2),
		UKE_ROUTE(UKE_QUP0 "i2c@a80000", "pinctrl-0", 1, 2, "gpio53", "qup0_se0_l1", 2),
		UKE_ROUTE(UKE_QUP0 "i2c@a80000", "pinctrl-1", 0, 1, "gpio52\0gpio53", "gpio", 2),
		UKE_ROUTE(UKE_QUP1 "i2c@890000", "pinctrl-0", 0, 2, "gpio176", "qup1_se4_l0", 2),
		UKE_ROUTE(UKE_QUP1 "i2c@890000", "pinctrl-0", 1, 2, "gpio177", "qup1_se4_l1", 2),
		UKE_ROUTE(UKE_QUP1 "i2c@890000", "pinctrl-1", 0, 1, "gpio176\0gpio177", "gpio", 2),
		UKE_ROUTE(UKE_QUP0 "spi@a90000", "pinctrl-0", 0, 3, "gpio17", "qup0_se4_l1", 6),
		UKE_ROUTE(UKE_QUP0 "spi@a90000", "pinctrl-0", 1, 3, "gpio16", "qup0_se4_l0", 6),
		UKE_ROUTE(UKE_QUP0 "spi@a90000", "pinctrl-0", 2, 3, "gpio18", "qup0_se4_l2", 6),
		UKE_ROUTE(UKE_QUP0 "spi@a90000", "pinctrl-1", 0, 3, "gpio17", "gpio", 2),
		UKE_ROUTE(UKE_QUP0 "spi@a90000", "pinctrl-1", 1, 3, "gpio16", "gpio", 2),
		UKE_ROUTE(UKE_QUP0 "spi@a90000", "pinctrl-1", 2, 3, "gpio18", "gpio", 2),
		UKE_ROUTE(UKE_QUP0 "spi@a90000/novatek@0", "pinctrl-0", 0, 1, "gpio19", "qup0_se4_l3", 6),
		UKE_ROUTE(UKE_QUP0 "spi@a90000/novatek@0", "pinctrl-1", 0, 1, "gpio19", "gpio", 2),
		UKE_ROUTE(UKE_QUP0 "i2c@a80000/wcd939x_i2c@e", "pinctrl-0", 0, 1, "gpio119", "gpio", 16),
		UKE_ROUTE(UKE_QUP0 "i2c@a80000/wcd939x_i2c@e", "pinctrl-1", 0, 1, "gpio119", "gpio", 16),
	};
	static const struct {
		const char *node, *property;
		unsigned int gpio, flags;
	} lines[] = {
		{ "/soc/ufshc@1d84000", "reset-gpios", 178, 1 },
		{ UKE_QUP0 "spi@a90000/novatek@0", "novatek,irq-gpio", 54, 0x2001 },
		{ UKE_QUP0 "spi@a90000/novatek@0", "novatek,lcd_id-gpio", 26, 0 },
		{ UKE_QUP0 "i2c@a80000/wcd939x_i2c@e", "reset-gpios", 119, 0 },
	};
	int tlmm = fdt_path_offset(fdt, tlmm_path), i, size;
	const fdt32_t *cells;
	unsigned int phandle = fdt_get_phandle(fdt, tlmm);

	if (tlmm < 0 || !phandle || fdt_node_check_compatible(fdt, tlmm, "qcom,cliffs-pinctrl") ||
	    uke_path_reg(fdt, tlmm_path, 0xf000000, 0x1000000))
		return -FDT_ERR_BADVALUE;
	cells = fdt_getprop(fdt, tlmm, "#gpio-cells", &size);
	if (!cells || size != 4 || fdt32_to_cpu(*cells) != 2)
		return -FDT_ERR_BADVALUE;
	for (i = 0; i < (int)(sizeof(lines) / sizeof(lines[0])); i++) {
		int node = fdt_path_offset(fdt, lines[i].node);

		cells = fdt_getprop(fdt, node, lines[i].property, &size);
		if (!cells || size != 12 || fdt32_to_cpu(cells[0]) != phandle ||
		    fdt32_to_cpu(cells[1]) != lines[i].gpio || fdt32_to_cpu(cells[2]) != lines[i].flags)
			return -FDT_ERR_BADVALUE;
	}
	for (i = 0; i < (int)(sizeof(routes) / sizeof(routes[0])); i++) {
		int node = fdt_path_offset(fdt, routes[i].bus), state, mux, config;
		const char *value;

		cells = fdt_getprop(fdt, node, routes[i].property, &size);
		if (!cells || size != (int)(routes[i].count * sizeof(*cells)))
			return -FDT_ERR_BADVALUE;
		state = fdt_node_offset_by_phandle(fdt, fdt32_to_cpu(cells[routes[i].slot]));
		if (state < 0)
			return -FDT_ERR_BADPHANDLE;
		/* Reject an identical-looking state attached to a foreign provider. */
		for (node = state; node >= 0 && node != tlmm; node = fdt_parent_offset(fdt, node))
			;
		if (node != tlmm)
			return -FDT_ERR_BADPHANDLE;
		mux = fdt_subnode_offset(fdt, state, "mux");
		config = fdt_subnode_offset(fdt, state, "config");
		value = fdt_getprop(fdt, mux, "pins", &size);
		if (!value || size != (int)routes[i].pin_bytes || memcmp(value, routes[i].pins, size))
			return -FDT_ERR_BADVALUE;
		value = fdt_getprop(fdt, config, "pins", &size);
		if (!value || size != (int)routes[i].pin_bytes || memcmp(value, routes[i].pins, size))
			return -FDT_ERR_BADVALUE;
		value = fdt_getprop(fdt, mux, "function", &size);
		if (!value || size != (int)strlen(routes[i].function) + 1 || strcmp(value, routes[i].function))
			return -FDT_ERR_BADVALUE;
		cells = fdt_getprop(fdt, config, "drive-strength", &size);
		if (!cells || size != 4 || fdt32_to_cpu(*cells) != routes[i].drive)
			return -FDT_ERR_BADVALUE;
	}
#undef UKE_ROUTE
#undef UKE_QUP1
#undef UKE_QUP0
	return 0;
}

#include "uke-bluetooth.h"

static int UKE_INIT uke_framebuffer(void *fdt)
{
	const fdt32_t *reg;
	fdt32_t framebuffer_reg[4];
	uint64_t address, length;
	char name[48], path[64];
	int splash, chosen, node, size, ret, backlight, panel;
	unsigned int phandle, panel_phandle;

	backlight = fdt_path_offset(fdt, "/soc/qcom,qupv3_0_geni_se@ac0000/i2c@a80000/ktz8866@11");
	if (backlight < 0)
		return backlight;
	phandle = fdt_get_phandle(fdt, backlight);
	if (!phandle) {
		ret = fdt_generate_phandle(fdt, &phandle);
		if (ret)
			return ret;
		ret = fdt_setprop_u32(fdt, backlight, "phandle", phandle);
		if (ret)
			return ret;
	}

	panel = fdt_add_subnode(fdt, 0, "panel-uke-handoff");
	if (panel < 0)
		return panel;
	ret = fdt_generate_phandle(fdt, &panel_phandle);
	if (ret)
		return ret;
#define UKE_FB_SET(call) do { ret = (call); if (ret) return ret; } while (0)
	/* Metadata only: do not power or reset the firmware-lit panel. */
	UKE_FB_SET(fdt_setprop_string(fdt, panel, "compatible", "xiaomi,uke-panel-handoff"));
	UKE_FB_SET(fdt_setprop_string(fdt, panel, "status", "disabled"));
	UKE_FB_SET(fdt_setprop_u32(fdt, panel, "phandle", panel_phandle));
	UKE_FB_SET(fdt_setprop_u32(fdt, panel, "width-mm", UKE_PANEL_WIDTH_MM));
	UKE_FB_SET(fdt_setprop_u32(fdt, panel, "height-mm", UKE_PANEL_HEIGHT_MM));

	splash = fdt_path_offset(fdt, "/reserved-memory/splash_region");
	if (splash < 0)
		return splash;
	reg = fdt_getprop(fdt, splash, "reg", &size);
	if (!reg || size != 16)
		return -FDT_ERR_BADVALUE;
	address = ((uint64_t)fdt32_to_cpu(reg[0]) << 32) | fdt32_to_cpu(reg[1]);
	length = ((uint64_t)fdt32_to_cpu(reg[2]) << 32) | fdt32_to_cpu(reg[3]);
	if (!address || (address & 4095) || length < UKE_FB_BYTES ||
	    length > 128 * 1024 * 1024 || address + length < address ||
	    fdt_getprop(fdt, splash, "reusable", NULL))
		return -FDT_ERR_BADVALUE;
	memcpy(framebuffer_reg, reg, 16);
	framebuffer_reg[2] = cpu_to_fdt32(0);
	framebuffer_reg[3] = cpu_to_fdt32(UKE_FB_BYTES);
	ret = fdt_setprop(fdt, splash, "no-map", NULL, 0);
	if (ret)
		return ret;
	chosen = fdt_path_offset(fdt, "/chosen");
	if (chosen < 0)
		return chosen;
	ret = fdt_setprop_u32(fdt, chosen, "#address-cells", 2);
	if (ret)
		return ret;
	ret = fdt_setprop_u32(fdt, chosen, "#size-cells", 2);
	if (ret)
		return ret;
	ret = fdt_setprop(fdt, chosen, "ranges", NULL, 0);
	if (ret)
		return ret;
	snprintf(name, sizeof(name), "framebuffer@%llx", (unsigned long long)address);
	node = fdt_subnode_offset(fdt, chosen, name);
	if (node == -FDT_ERR_NOTFOUND)
		node = fdt_add_subnode(fdt, chosen, name);
	if (node < 0)
		return node;
	UKE_FB_SET(fdt_setprop_string(fdt, node, "compatible", "simple-framebuffer"));
	UKE_FB_SET(fdt_setprop_u32(fdt, node, "panel", panel_phandle));
	UKE_FB_SET(fdt_setprop_u32(fdt, node, "backlight", phandle));
	UKE_FB_SET(fdt_setprop(fdt, node, "reg", framebuffer_reg, sizeof(framebuffer_reg)));
	UKE_FB_SET(fdt_setprop_u32(fdt, node, "width", UKE_FB_WIDTH));
	UKE_FB_SET(fdt_setprop_u32(fdt, node, "height", UKE_FB_HEIGHT));
	UKE_FB_SET(fdt_setprop_u32(fdt, node, "stride", UKE_FB_STRIDE));
	UKE_FB_SET(fdt_setprop_string(fdt, node, "format", "a8r8g8b8"));
	UKE_FB_SET(fdt_setprop_string(fdt, node, "status", "okay"));
	snprintf(path, sizeof(path), "/chosen/%s", name);
	chosen = fdt_path_offset(fdt, "/chosen");
	UKE_FB_SET(fdt_setprop_string(fdt, chosen, "stdout-path", path));
#undef UKE_FB_SET
	return 0;
}

/* 0: foreign DT left untouched; 1: admitted graph; negative: reject Uke boot.
 * Overlay buffers are private writable copies: libfdt consumes them. Never
 * write to the incoming bootloader FDT, including on partial overlay failure.
 */
#ifdef __KERNEL__
static
#endif
int UKE_INIT uke_abl_transform(void *output, size_t capacity,
			      const void *input, size_t input_bytes,
			      void *ufs_overlay, size_t ufs_bytes,
			      void *usb_overlay, size_t usb_bytes)
{
	static const char model[] = "Qualcomm Technologies, Inc. Uke based on SM8635";
	const char *value;
	const fdt32_t *board;
	int size, ret;

	if (!input || input_bytes < sizeof(struct fdt_header) || input_bytes > UKE_FDT_CAPACITY ||
	    fdt_check_full(input, input_bytes))
		return -FDT_ERR_BADSTRUCTURE;
	value = fdt_getprop(input, 0, "model", &size);
	if (!value || size != (int)sizeof(model) || memcmp(value, model, sizeof(model)))
		return 0;
	board = fdt_getprop(input, 0, "qcom,board-id", &size);
	if (!board || size != 8 || fdt32_to_cpu(board[0]) != 8 ||
	    fdt32_to_cpu(board[1]) != 0 ||
	    fdt_node_check_compatible(input, 0, "qcom,cliffs-mtp") ||
	    capacity > UKE_FDT_CAPACITY || capacity <= input_bytes ||
	    uke_ufs_admit(input) ||
	    uke_path_reg(input, "/soc/ufsphy_mem@1d80000", 0x1d80000, 0x2000) ||
	    uke_reboot_cell(input) || uke_wifi_graph(input) || uke_legacy_layout(input) || uke_gpu_opps(input) ||
	    uke_backlight_bus(input) || uke_spi_graph(input) || uke_board_pins(input) ||
	    !ufs_overlay || !usb_overlay ||
	    ufs_bytes < sizeof(struct fdt_header) || usb_bytes < sizeof(struct fdt_header) ||
	    fdt_check_full(ufs_overlay, ufs_bytes) ||
	    fdt_check_full(usb_overlay, usb_bytes))
		return -FDT_ERR_BADVALUE;
#if defined(UKE_LLCC_NATIVE_PROFILE) && UKE_LLCC_NATIVE_PROFILE
	ret = uke_llcc_admit(input);
	if (ret)
		return ret;
#endif
	ret = fdt_open_into(input, output, capacity);
	if (ret)
		return ret;
	ret = fdt_overlay_apply(output, ufs_overlay);
	if (ret)
		return ret;
	ret = fdt_overlay_apply(output, usb_overlay);
	if (ret)
		return ret;
#if defined(UKE_LLCC_NATIVE_PROFILE) && UKE_LLCC_NATIVE_PROFILE
	ret = uke_llcc_apply(output);
	if (ret)
		return ret;
#endif
	/* OEM zero-width bits means the whole byte; upstream rejects bits=<0 0>. */
	ret = uke_delete_optional(output, "/soc/qcom,spmi@c42d000/qcom,pmk8550@0/sdam@7000/ufs_dev@ad", "bits");
	if (ret)
		return ret;
	ret = uke_delete_optional(output, "/soc/ufshc@1d84000", "msi-parent");
	if (ret)
		return ret;
	ret = uke_delete_optional(output, "/soc/ufshc@1d84000", "shared-ice-cfg");
	if (ret)
		return ret;
	ret = uke_delete_optional(output, "/soc/ssusb@a600000", "extcon");
	if (ret)
		return ret;
	{
		const char *path = "/soc/ssusb@a600000";
		int usb = fdt_path_offset(output, path);
		int typec = !fdt_node_check_compatible(output, usb, "qcom,sm7675-dwc3-typec");
		const char *const full_remove[] = {
			"usb-phy", "interrupts", "qcom,select-utmi-as-pipe-clk"
		};
		unsigned int i;

		if (typec) {
			const void *property = fdt_getprop(output, usb, "interrupts-extended", &size);
			if (!property || size != 17 * sizeof(fdt32_t) ||
			    !fdt_getprop(output, usb, "usb-role-switch", NULL))
				return -FDT_ERR_BADVALUE;
			for (i = 0; i < sizeof(full_remove) / sizeof(full_remove[0]); i++) {
				ret = uke_delete_optional(output, path, full_remove[i]);
				if (ret)
					return ret;
			}
			/* Remove the inherited OEM single port before using ports@0/1. */
			usb = fdt_path_offset(output, "/soc/ssusb@a600000/port");
			if (usb >= 0 && (ret = fdt_del_node(output, usb)))
				return ret;
		} else {
			ret = uke_delete_optional(output, path, "interrupts-extended");
			if (ret)
				return ret;
			ret = uke_delete_optional(output, path, "usb-role-switch");
			if (ret)
				return ret;
		}
	}
	ret = uke_scope_qup_buses(output);
	if (ret)
		return ret;
	ret = uke_empty_spmi_bus(output);
	if (ret)
		return ret;
	ret = uke_legacy_va_gpio_flag(output);
	if (ret)
		return ret;
	ret = uke_empty_demura_regions(output);
	if (ret)
		return ret;
	ret = uke_pair_backlights(output);
	if (ret)
		return ret;
	/* shortcut: firmware display has no native panel driver; restore the
	 * touch-panel lifecycle link when the O82 DRM panel port is admitted.
	 */
	ret = uke_delete_optional(output, "/soc/qcom,qupv3_0_geni_se@ac0000/spi@a90000/novatek@0", "panel");
	if (ret)
		return ret;
	/* OEM selects these CS states in its driver; the Linux core uses these names. */
	ret = fdt_setprop(output,
		fdt_path_offset(output, "/soc/qcom,qupv3_0_geni_se@ac0000/spi@a90000/novatek@0"),
		"pinctrl-names", "default\0sleep", sizeof("default\0sleep"));
	if (ret)
		return ret;
	ret = fdt_setprop_string(output,
		fdt_path_offset(output, "/soc/qcom,qupv3_0_geni_se@ac0000/spi@a90000/goodix-berlin@0"),
		"status", "disabled");
	if (ret)
		return ret;
	ret = uke_scope_smmu_clients(output);
	if (ret)
		return ret;
	ret = uke_sensor_fastrpc(output);
	if (ret)
		return ret;
	ret = uke_cpu_thermal(output);
	if (ret)
		return ret;
	ret = uke_clock_debug_retire(output);
	if (ret)
		return ret;
	ret = uke_pmic_adc(output);
	if (ret)
		return ret;
	ret = uke_volume_down_wake(output);
	if (ret)
		return ret;
	ret = uke_hall(output);
	if (ret)
		return ret;
	ret = uke_bluetooth(output);
	if (ret)
		return ret;
	ret = uke_framebuffer(output);
	if (ret)
		return ret;
	ret = fdt_pack(output);
	return ret ? ret : 1;
}

#ifdef __KERNEL__
/* Persistent kernel-owned storage: OF and /sys/firmware/fdt retain pointers
 * after free_initmem(). The original bootloader allocation stays reserved.
 */
static unsigned char uke_fdt[UKE_FDT_CAPACITY] __ro_after_init __aligned(8);
#include "uke-abl-overlays.h"
#include "uke-lights.h"

void *__init uke_abl_prepare_fdt(void *input, int size, phys_addr_t *physical)
{
	int ret;

	if (!input || size <= 0)
		return input;
	ret = uke_abl_transform(uke_fdt, sizeof(uke_fdt), input, size,
			      uke_ufs_overlay, sizeof(uke_ufs_overlay),
			      uke_usb_overlay, sizeof(uke_usb_overlay));
	if (ret < 0) {
		pr_crit("Uke ABL DT adaptation rejected (%d); refusing incomplete board graph\n", ret);
		while (true)
			cpu_relax();
	}
	if (!ret)
		return input;
	if (uke_lights_admitted(input)) {
		ret = fdt_open_into(uke_fdt, uke_fdt, sizeof(uke_fdt));
		if (!ret)
			ret = fdt_overlay_apply(uke_fdt, uke_lights_overlay);
		if (!ret)
			ret = fdt_pack(uke_fdt);
		if (ret) {
			pr_crit("Uke light overlay rejected (%d); refusing a partial graph\n", ret);
			while (true)
				cpu_relax();
		}
	} else {
		pr_warn("Uke lights: OEM graph not admitted; light controls unavailable\n");
	}
	*physical = __pa_symbol(uke_fdt);
	pr_info("Uke ABL DT: selected RAM preserved; UFS, selected USB profile and simplefb prepared\n");
	return uke_fdt;
}

void __init uke_abl_prepare_cmdline(const void *fdt, char *cmdline,
				  size_t capacity)
{
	const char *handoff;
	int chosen, bytes = 0;

	if (fdt != uke_fdt)
		return;
	chosen = fdt_path_offset(fdt, "/chosen");
	handoff = fdt_getprop(fdt, chosen, "bootargs", &bytes);
	if (!handoff && bytes == -FDT_ERR_NOTFOUND)
		bytes = 0;
	if (bytes < 0 || uke_select_root(cmdline, capacity, handoff, bytes) < 0) {
		pr_crit("Uke root selector rejected; refusing an ambiguous root\n");
		while (true)
			cpu_relax();
	}
}
#endif
