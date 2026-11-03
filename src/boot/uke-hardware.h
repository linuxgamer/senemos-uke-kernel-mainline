/* SPDX-License-Identifier: GPL-2.0-only */
/* Board identity and firmware-owned sensor descriptions; no bus probing. */
static int UKE_INIT uke_hardware_child(void *fdt, int parent, const char *name)
{
	int node = fdt_subnode_offset(fdt, parent, name);

	return node == -FDT_ERR_NOTFOUND ? fdt_add_subnode(fdt, parent, name) : node;
}

static int UKE_INIT uke_hardware_llcc_pmu(void *fdt)
{
	const char *path = "/soc/llcc-pmu@24095000";
	const char *name, *value;
	const fdt32_t *reg;
	int node = fdt_path_offset(fdt, path), soc, bytes, property;

	if (node == -FDT_ERR_NOTFOUND)
		return 0;
	if (node < 0)
		return node;
	soc = fdt_path_offset(fdt, "/soc");
	if (soc < 0 || fdt_address_cells(fdt, soc) != 1 || fdt_size_cells(fdt, soc) != 1)
		return -FDT_ERR_BADVALUE;
	reg = (const fdt32_t *)fdt_getprop(fdt, node, "reg", &bytes);
	if (!reg || bytes != 8 || fdt32_to_cpu(reg[0]) != 0x24095000 || fdt32_to_cpu(reg[1]) != 0x300)
		return -FDT_ERR_BADVALUE;
	value = (const char *)fdt_getprop(fdt, node, "reg-names", &bytes);
	if (!value || bytes != 10 || memcmp(value, "lagg-base", 10))
		return -FDT_ERR_BADVALUE;
	value = (const char *)fdt_getprop(fdt, node, "compatible", &bytes);
	if (!value || !((bytes == sizeof("qcom,llcc-pmu-ver2") && !memcmp(value, "qcom,llcc-pmu-ver2", bytes)) ||
		       (bytes == sizeof("qcom,sm7675-llcc-pmu") && !memcmp(value, "qcom,sm7675-llcc-pmu", bytes))))
		return -FDT_ERR_BADVALUE;
	value = (const char *)fdt_getprop(fdt, node, "status", &bytes);
	if (value && !((bytes == 5 && !memcmp(value, "okay", 5)) ||
		       (bytes == 3 && !memcmp(value, "ok", 3)) ||
		       (bytes == 9 && !memcmp(value, "disabled", 9))))
		return -FDT_ERR_BADVALUE;
	if (fdt_first_subnode(fdt, node) != -FDT_ERR_NOTFOUND)
		return -FDT_ERR_BADVALUE;
	fdt_for_each_property_offset(property, fdt, node) {
		if (!fdt_getprop_by_offset(fdt, property, &name, &bytes) ||
		    (strcmp(name, "compatible") && strcmp(name, "reg") && strcmp(name, "reg-names") &&
		     strcmp(name, "status") && strcmp(name, "phandle") && strcmp(name, "linux,phandle")))
			return -FDT_ERR_BADVALUE;
	}
	if (property != -FDT_ERR_NOTFOUND)
		return property;
	/* Retain disabled/absent status; probe only reads registers until a perf event starts. */
	return fdt_setprop_string(fdt, node, "compatible", "qcom,sm7675-llcc-pmu");
}

static int UKE_INIT uke_hardware_rng(void *fdt)
{
	static const char compatible[] = "qcom,sm7675-trng\0qcom,trng";
	const fdt32_t *reg;
	int node = fdt_path_offset(fdt, "/soc/qrng@10c3000"), bytes, ret;
	unsigned int i;
	static const char *const legacy[] = { "qcom,no-qrng-config", "qcom,no-clock-support" };
	bool converted;

	if (node == -FDT_ERR_NOTFOUND)
		return 0;
	if (node < 0)
		return node;
	reg = (const fdt32_t *)fdt_getprop(fdt, node, "reg", &bytes);
	if (!reg || bytes != 8 || fdt32_to_cpu(reg[0]) != 0x10c3000 ||
	    fdt32_to_cpu(reg[1]) != 0x1000 || fdt_getprop(fdt, node, "clocks", NULL) ||
	    fdt_getprop(fdt, node, "clock-names", NULL))
		return -FDT_ERR_BADVALUE;
	converted = !fdt_node_check_compatible(fdt, node, "qcom,sm7675-trng") &&
		    !fdt_node_check_compatible(fdt, node, "qcom,trng");
	if (!converted) {
		if (fdt_node_check_compatible(fdt, node, "qcom,msm-rng"))
			return -FDT_ERR_BADVALUE;
		for (i = 0; i < ARRAY_SIZE(legacy); i++)
			if (!fdt_getprop(fdt, node, legacy[i], &bytes) || bytes)
				return -FDT_ERR_BADVALUE;
	}
	/* The firmware owns setup: upstream TRNG reads the FIFO without reprogramming it. */
	ret = fdt_setprop(fdt, node, "compatible", compatible, sizeof(compatible));
	if (ret)
		return ret;
	for (i = 0; i < ARRAY_SIZE(legacy); i++) {
		node = fdt_path_offset(fdt, "/soc/qrng@10c3000");
		ret = fdt_delprop(fdt, node, legacy[i]);
		if (ret && ret != -FDT_ERR_NOTFOUND)
			return ret;
	}
	return 0;
}

static int UKE_INIT uke_hardware_names(void *fdt)
{
	static const struct {
		const char *node, *label, *type, *candidates;
		unsigned int bytes;
	} sensors[] = {
#define UKE_SENSOR(n, l, t, m) { n, l, t, m, sizeof(m) }
		UKE_SENSOR("accelerometer", "Accelerometer", "accel", "LSM6DSO\0QMI8658"),
		UKE_SENSOR("gyroscope", "Gyroscope", "gyro", "LSM6DSO\0QMI8658"),
		UKE_SENSOR("magnetometer", "Magnetometer", "mag", "QMC630x"),
		UKE_SENSOR("front-light", "Front ambient light", "ambient_light", "STK3BCx"),
		UKE_SENSOR("rear-light", "Rear ambient light", "ambient_light_back", "SIP1328"),
		UKE_SENSOR("color-temperature", "Front color temperature", "cct_front", "STK3BCx"),
		UKE_SENSOR("proximity", "Proximity", "proximity", "STK3BCx"),
		UKE_SENSOR("flicker", "Flicker", "flicker", "SIP1328"),
		UKE_SENSOR("sar", "Capacitive SAR", "sar", "SX937x"),
#undef UKE_SENSOR
	};
	static const char *const cores[] = {
		"arm,cortex-a520", "arm,cortex-a520", "arm,cortex-a520",
		"arm,cortex-a720", "arm,cortex-a720", "arm,cortex-a720",
		"arm,cortex-a720", "arm,cortex-x4",
	};
	const char *processor = "Qualcomm Snapdragon 7+ Gen 3";
	static const struct { const char *path, *model; } names[] = {
		{ "/soc/qcom,kgsl-3d0@3d00000", "Qualcomm Adreno 732" },
		{ "/soc/qcom,gmu@3d69000", "Qualcomm Adreno 732 GMU" },
		{ "/soc/qcom,wcn6750", "Qualcomm WCN6750 Wi-Fi" },
		{ "/soc/qcom,qupv3_1_geni_se@8c0000/qcom,qup_uart@888000/bluetooth", "Qualcomm WCN6750 Bluetooth" },
		{ "/soc/ufshc@1d84000", "Qualcomm SM7675 UFS controller" },
		{ "/soc/qcom,qupv3_0_geni_se@ac0000/i2c@a80000/wcd939x_i2c@e", "Qualcomm WCD939x USB/Type-C switch" },
		{ "/soc/spf_core_platform/lpass-cdc/wcd939x-codec", "Qualcomm WCD939x audio codec" },
	};
	static const struct { const char *path, *label; } roles[] = {
		{ "/soc/qcom,cci0@ac15000/qcom,cam-sensor0", "Rear camera" },
		{ "/soc/qcom,qupv3_1_geni_se@8c0000/i2c@880000/qcom,cam-sensor1", "Front camera" },
		{ "/soc/qcom,cci0@ac15000/qcom,eeprom0", "Rear camera EEPROM" },
		{ "/soc/qcom,qupv3_1_geni_se@8c0000/i2c@880000/qcom,eeprom1", "Front camera EEPROM" },
		{ "/soc/qcom,cci0@ac15000/qcom,actuator0", "Rear camera autofocus actuator" },
	};
	char path[64];
	unsigned int i;
	int node, parent, ret;

	if (fdt_node_check_compatible(fdt, 0, "xiaomi,uke") ||
	    fdt_node_check_compatible(fdt, 0, "qcom,sm7675"))
		return -FDT_ERR_BADVALUE;
	ret = uke_hardware_rng(fdt);
	if (ret)
		return ret;
	ret = uke_hardware_llcc_pmu(fdt);
	if (ret)
		return ret;
	node = fdt_path_offset(fdt, "/soc/xiaomi_fingerprint");
	if (node >= 0) {
		ret = fdt_setprop_string(fdt, node, "status", "disabled");
		if (ret)
			return ret;
	}
	node = fdt_path_offset(fdt, "/soc/qcom,qupv3_1_geni_se@8c0000/i2c@890000/ntag@57");
	if (node >= 0) {
		int bytes;
		const fdt32_t *old = (const fdt32_t *)fdt_getprop(fdt, node, "qcom,ntag-vdd-supply", &bytes);

		if (old) {
			fdt32_t supply;

			if (bytes != sizeof(supply))
				return -FDT_ERR_BADVALUE;
			supply = *old;
			ret = fdt_setprop(fdt, node, "vdd-supply", &supply, sizeof(supply));
			if (ret)
				return ret;
		}
	}
	for (i = 0; i < ARRAY_SIZE(names); i++) {
		node = fdt_path_offset(fdt, names[i].path);
		if (node < 0)
			continue;
		ret = fdt_setprop_string(fdt, node, "model", names[i].model);
		if (ret)
			return ret;
	}
	for (i = 0; i < ARRAY_SIZE(roles); i++) {
		node = fdt_path_offset(fdt, roles[i].path);
		if (node < 0)
			continue;
		ret = fdt_setprop_string(fdt, node, "label", roles[i].label);
		if (ret)
			return ret;
	}
	parent = fdt_path_offset(fdt, "/cpus");
	if (parent < 0)
		return parent;
	ret = fdt_setprop_string(fdt, parent, "model", processor);
	if (ret)
		return ret;
	for (i = 0; i < ARRAY_SIZE(cores); i++) {
		snprintf(path, sizeof(path), "/cpus/cpu@%x", i * 0x100);
		node = fdt_path_offset(fdt, path);
		if (node < 0)
			return node;
		ret = fdt_setprop_string(fdt, node, "compatible", cores[i]);
		if (ret)
			return ret;
		node = fdt_path_offset(fdt, path);
		ret = fdt_setprop_string(fdt, node, "model", processor);
		if (ret)
			return ret;
	}
	/* Product specifications identify the technology, not the fitted vendor. */
	node = fdt_path_offset(fdt, "/memory");
	if (node >= 0) {
		ret = fdt_setprop_string(fdt, node, "model", "LPDDR5X");
		if (ret)
			return ret;
	}
	node = fdt_path_offset(fdt, "/soc/qcom,qupv3_0_geni_se@ac0000/i2c@a8c000/nanosic@4c");
	if (node >= 0) {
		ret = fdt_setprop_string(fdt, node, "model", "Xiaomi Focus Keyboard");
		if (ret)
			return ret;
	}
	parent = fdt_path_offset(fdt, "/firmware");
	if (parent < 0)
		return parent;
	node = uke_hardware_child(fdt, parent, "uke-accessories");
	if (node < 0)
		return node;
	ret = fdt_setprop_string(fdt, node, "compatible", "xiaomi,uke-accessory-profile");
	if (ret)
		return ret;
	node = fdt_path_offset(fdt, "/firmware/uke-accessories");
	ret = fdt_setprop_string(fdt, node, "pen-model", "Xiaomi Focus Pen");
	if (ret)
		return ret;
	node = fdt_path_offset(fdt, "/firmware/uke-accessories");
	ret = fdt_setprop_string(fdt, node, "keyboard-model", "Xiaomi Focus Keyboard");
	if (ret)
		return ret;
	parent = fdt_path_offset(fdt, "/firmware");
	node = uke_hardware_child(fdt, parent, "ssc-sensors");
	if (node < 0)
		return node;
	ret = fdt_setprop_string(fdt, node, "compatible", "xiaomi,uke-ssc-sensors");
	if (ret)
		return ret;
	node = fdt_path_offset(fdt, "/firmware/ssc-sensors");
	{
		int adsp = fdt_path_offset(fdt, "/soc/remoteproc-adsp@03000000");
		unsigned int phandle = adsp < 0 ? 0 : fdt_get_phandle(fdt, adsp);

		if (!phandle)
			return -FDT_ERR_BADPHANDLE;
		ret = fdt_setprop_u32(fdt, node, "remoteproc", phandle);
		if (ret)
			return ret;
	}
	for (i = 0; i < ARRAY_SIZE(sensors); i++) {
		parent = fdt_path_offset(fdt, "/firmware/ssc-sensors");
		node = uke_hardware_child(fdt, parent, sensors[i].node);
		if (node < 0)
			return node;
		ret = fdt_setprop_string(fdt, node, "compatible", "xiaomi,uke-ssc-sensor");
		if (ret)
			return ret;
		snprintf(path, sizeof(path), "/firmware/ssc-sensors/%s", sensors[i].node);
		node = fdt_path_offset(fdt, path);
		ret = fdt_setprop_string(fdt, node, "label", sensors[i].label);
		if (ret)
			return ret;
		node = fdt_path_offset(fdt, path);
		ret = fdt_setprop_string(fdt, node, "qcom,ssc-datatype", sensors[i].type);
		if (ret)
			return ret;
		node = fdt_path_offset(fdt, path);
		ret = fdt_setprop(fdt, node, "xiaomi,model-candidates",
				 sensors[i].candidates, sensors[i].bytes);
		if (ret)
			return ret;
	}
	return 0;
}

static int UKE_INIT uke_hardware_below(const char *path, const char *parent)
{
	size_t length = strlen(parent);

	return !strncmp(path, parent, length) && (!path[length] || path[length] == '/');
}

/* Unknown cell properties also count as references: retain uncertain nodes. */
static int UKE_INIT uke_hardware_referenced(const void *fdt, const char *path)
{
	fdt32_t handles[256];
	unsigned int count = 0, i;
	int node, property, bytes, pos, start = fdt_path_offset(fdt, path);
	int end = start, depth = 0, next;

	if (start < 0)
		return 1;
	node = fdt_path_offset(fdt, "/aliases");
	if (node >= 0)
		fdt_for_each_property_offset(property, fdt, node) {
			const char *value = (const char *)fdt_getprop_by_offset(fdt, property, NULL, &bytes);

			if (value && bytes > 0 && !value[bytes - 1] &&
			    uke_hardware_below(value, path))
				return 1;
		}
	do {
		unsigned int handle;
		unsigned int tag = fdt_next_tag(fdt, end, &next);

		if (next < 0)
			return 1;
		if (tag == FDT_BEGIN_NODE) {
			depth++;
			handle = fdt_get_phandle(fdt, end);
			if (handle) {
				if (count == ARRAY_SIZE(handles))
					return 1;
				handles[count++] = cpu_to_fdt32(handle);
			}
		} else if (tag == FDT_END_NODE) {
			depth--;
		} else if (tag != FDT_PROP && tag != FDT_NOP) {
			return 1;
		}
		end = next;
	} while (depth > 0);
	if (!count)
		return 0;
	for (node = fdt_next_node(fdt, -1, NULL); node >= 0;
	     node = fdt_next_node(fdt, node, NULL)) {
		if (node >= start && node < end)
			continue;
		fdt_for_each_property_offset(property, fdt, node) {
			const char *name;
			const fdt32_t *cells = (const fdt32_t *)fdt_getprop_by_offset(fdt, property, &name, &bytes);

			if (!cells || bytes % 4)
				continue;
			/* These bindings contain addresses, measurements or register data. */
			if (!strcmp(name, "reg") || !strcmp(name, "ranges") ||
			    !strcmp(name, "dma-ranges") || !strcmp(name, "interrupts") ||
			    !strcmp(name, "qcom,mdss-pan-physical-height-dimension") ||
			    !strcmp(name, "qcom,phy-debug-reg") || !strcmp(name, "qcom,phy-sequence") ||
			    !strcmp(name, "qcom,dump-size") || !strcmp(name, "qcom,phy-version"))
				continue;
			for (pos = 0; pos < bytes / 4; pos++)
				for (i = 0; i < count; i++)
					if (cells[pos] == handles[i])
						return 1;
		}
	}
	return 0;
}

static int UKE_INIT uke_hardware_drop(void *fdt, const char *path)
{
	int node = fdt_path_offset(fdt, path), ret, property, bytes;

	if (node == -FDT_ERR_NOTFOUND)
		return 0;
	if (node < 0)
		return node;
	if (uke_hardware_referenced(fdt, path))
		return 0;
	ret = fdt_del_node(fdt, node);
	if (ret)
		return ret;
	for (;;) {
		node = fdt_path_offset(fdt, "/__symbols__");
		if (node < 0)
			return node;
		fdt_for_each_property_offset(property, fdt, node) {
			const char *name, *value = (const char *)fdt_getprop_by_offset(fdt, property, &name, &bytes);

			if (value && bytes > 0 && !value[bytes - 1] &&
			    uke_hardware_below(value, path)) {
				ret = fdt_delprop(fdt, node, name);
				if (ret)
					return ret;
				break;
			}
		}
		if (property == -FDT_ERR_NOTFOUND)
			return 1;
		if (property < 0)
			return property;
	}
}

static int UKE_INIT uke_hardware_simplify(void *fdt)
{
	const char *parent = "/soc/qcom,mdss_mdp@ae00000";
	char path[512];
	int node, child, ret, removed;

	/* Uke has no fingerprint sensor; shared OEM files include this template. */
	ret = uke_hardware_drop(fdt, "/soc/xiaomi_fingerprint");
	if (ret < 0)
		return ret;
	/* The selected NT36532 driver has no Goodix or OEM MP-test consumer. */
	{
		static const char *const unused[] = {
			"/soc/qcom,qupv3_0_geni_se@ac0000/spi@a90000/goodix-berlin@0",
			"/soc/qcom,qupv3_0_geni_se@ac0000/spi@a90000/novatek@0/novatek-mp-criteria-5993@0",
			"/soc/qcom,qupv3_0_geni_se@ac0000/spi@a90000/novatek@0/novatek-mp-criteria-5994@0",
		};
		unsigned int i;

		for (i = 0; i < ARRAY_SIZE(unused); i++) {
			ret = uke_hardware_drop(fdt, unused[i]);
			if (ret < 0)
				return ret;
		}
	}
	do {
		removed = 0;
		node = fdt_path_offset(fdt, parent);
		if (node < 0)
			return node == -FDT_ERR_NOTFOUND ? 0 : node;
		fdt_for_each_subnode(child, fdt, node) {
			if (!fdt_getprop(fdt, child, "qcom,mdss-dsi-panel-name", NULL))
				continue;
			if (fdt_get_path(fdt, child, path, sizeof(path)))
				return -FDT_ERR_NOSPACE;
			ret = uke_hardware_drop(fdt, path);
			if (ret < 0)
				return ret;
			if (ret) {
				removed = 1;
				break;
			}
		}
	} while (removed);
	return 0;
}
