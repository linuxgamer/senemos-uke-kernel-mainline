/* SPDX-License-Identifier: GPL-2.0-only */
/* Uke's inherited PM8010 N template is optional in the firmware population. */
#if IS_ENABLED(CONFIG_QCOM_UKE_ABL_DT) && IS_REACHABLE(CONFIG_QCOM_SMEM) && \
    IS_REACHABLE(CONFIG_QCOM_COMMAND_DB)
#include <linux/soc/qcom/smem.h>
#include <linux/soc/qcom/socinfo.h>
#include <linux/unaligned.h>
#include <soc/qcom/cmd-db.h>

static int uke_pm8010_inventory(const void *data, size_t size)
{
	size_t header = offsetof(struct socinfo, pmic_array_offset) + sizeof(__le32);
	u32 count, offset, format, i;
	bool present = false;

	if (!data || size < header)
		return -EINVAL;
	format = get_unaligned_le32((const u8 *)data + offsetof(struct socinfo, fmt));
	if (SOCINFO_MAJOR(format) != 0 || SOCINFO_MINOR(format) < 11)
		return -EINVAL;
	count = get_unaligned_le32((const u8 *)data + offsetof(struct socinfo, num_pmics));
	offset = get_unaligned_le32((const u8 *)data + offsetof(struct socinfo, pmic_array_offset));
	if (!count || count > 64 || offset < header || offset % sizeof(__le32) ||
	    offset > size || count > (size - offset) / (2 * sizeof(__le32)))
		return -EINVAL;
	for (i = 0; i < count; i++) {
		u32 model = SOCINFO_MINOR(get_unaligned_le32((const u8 *)data +
						 offset + i * 2 * sizeof(__le32)));

		if (!model)
			return -ENODATA;
		if (model == 65) /* PM8010, as defined by Qualcomm socinfo. */
			present = true;
	}
	return present;
}

static int uke_pm8010_should_probe(struct spmi_device *sdev)
{
	struct device_node *node;
	const void *info;
	size_t size;
	char resource[] = "ldon1";
	int ret, i;

	if (!of_machine_is_compatible("xiaomi,uke") || sdev->usid != 0x0d)
		return 1;
	node = of_find_node_by_path("/soc/qcom,spmi@c42d000/qcom,pm8010@d");
	ret = node && node == sdev->dev.of_node;
	of_node_put(node);
	if (!ret)
		return 1;

	info = qcom_smem_get(QCOM_SMEM_HOST_ANY, SMEM_HW_SW_BUILD_ID, &size);
	if (IS_ERR(info))
		return PTR_ERR(info);
	ret = uke_pm8010_inventory(info, size);
	if (ret)
		return ret;
	ret = cmd_db_ready();
	if (ret)
		return ret;
	for (i = 0; i < 7; i++) {
		resource[4] = '1' + i;
		if (cmd_db_read_addr(resource))
			return 1;
	}

	/* Never infer absence from a failed SPMI read or change a power/reset line. */
	dev_info(&sdev->dev, "PM8010 N is not advertised by firmware inventory or RPMh; skipping the inherited template\n");
	return 0;
}
#else
static int uke_pm8010_should_probe(struct spmi_device *sdev)
{
	return 1;
}
#endif
