// SPDX-License-Identifier: GPL-2.0-only
/* Copyright (c) 2022 Qualcomm Innovation Center, Inc. All rights reserved.
 * Manually loaded, read-only Uke CPUCP MEMLAT/C1DCVS diagnostic.
 * Qualcomm protocol source: MiCode 5712080a and July 2026 RFC patch 03/10.
 * No configuration, start, stop, log flush or automatic module loading.
 */
#include <linux/module.h>
#include <linux/of.h>
#include <linux/scmi_protocol.h>
#include <linux/string.h>
#include <linux/utsname.h>
#include "protocols.h"

#define UKE_MEMLAT_PROTOCOL 0x80
#define UKE_MEMLAT_ALGO 0x4d454d4c4154ULL
#define UKE_MEMLAT_GET_FREQ 35
#define UKE_MEMLAT_GET_TIMESTAMP 38
#define UKE_C1DCVS_ALGO 0x433144435653ULL
#define UKE_C1DCVS_GET_ENABLE 1

struct uke_memlat_header {
	__le32 reserved, algo_low, algo_high, parameter;
};

static int query_rc = -EINPROGRESS;
module_param(query_rc, int, 0444);
MODULE_PARM_DESC(query_rc, "First timestamp GET result; zero is not policy acceptance");
static int c1dcvs_rc = -EINPROGRESS;
module_param(c1dcvs_rc, int, 0444);
MODULE_PARM_DESC(c1dcvs_rc, "C1DCVS enable GET result; no setting is changed");
static int c1dcvs_enabled = -1;
module_param(c1dcvs_enabled, int, 0444);
MODULE_PARM_DESC(c1dcvs_enabled, "Observed C1DCVS enable bit, or -1 when unknown");

static int uke_cpucp_get(const struct scmi_protocol_handle *ph, u64 algorithm, u32 parameter,
			 const void *request, size_t tx_len, void *reply, size_t rx_len)
{
	struct uke_memlat_header *header;
	struct scmi_xfer *transfer;
	int ret;

	if (!ph || !ph->xops || !reply ||
	    !((algorithm == UKE_MEMLAT_ALGO &&
	       ((parameter == UKE_MEMLAT_GET_TIMESTAMP && !tx_len && rx_len == 8) ||
		(parameter == UKE_MEMLAT_GET_FREQ && request && tx_len == 12 && rx_len == 4))) ||
	      (algorithm == UKE_C1DCVS_ALGO && parameter == UKE_C1DCVS_GET_ENABLE &&
	       !tx_len && rx_len == 4)))
		return -EINVAL;
	/* shmem_fetch_response() clips to capacity; retain an overlength sentinel. */
	ret = ph->xops->xfer_get_init(ph, 0x11, sizeof(*header) + tx_len,
				      rx_len + sizeof(__le32), &transfer);
	if (ret)
		return ret;
	header = transfer->tx.buf;
	header->reserved = 0;
	header->algo_low = cpu_to_le32(lower_32_bits(algorithm));
	header->algo_high = cpu_to_le32(upper_32_bits(algorithm));
	header->parameter = cpu_to_le32(parameter);
	if (tx_len)
		memcpy(header + 1, request, tx_len);
	ret = ph->xops->do_xfer(ph, transfer);
	if (!ret) {
		if (transfer->rx.len != rx_len)
			ret = -EPROTO;
		else
			memcpy(reply, transfer->rx.buf, rx_len);
	}
	ph->xops->xfer_put(ph, transfer);
	return ret;
}

static int uke_memlat_get(const struct scmi_protocol_handle *ph, u32 parameter,
			 const void *request, size_t tx_len, void *reply, size_t rx_len)
{
	return uke_cpucp_get(ph, UKE_MEMLAT_ALGO, parameter, request, tx_len, reply, rx_len);
}

static int uke_c1dcvs_get_enable(const struct scmi_protocol_handle *ph, __le32 *reply)
{
	__le32 value;
	int ret;

	if (!reply)
		return -EINVAL;
	ret = uke_cpucp_get(ph, UKE_C1DCVS_ALGO, UKE_C1DCVS_GET_ENABLE,
			    NULL, 0, &value, sizeof(value));
	if (ret)
		return ret;
	if (le32_to_cpu(value) > 1)
		return -EPROTO;
	*reply = value;
	return 0;
}

static int uke_cpucp_version_get(const struct scmi_protocol_handle *ph, u32 *version)
{
	struct scmi_xfer *transfer;
	__le32 value;
	int ret;

	if (!ph || !ph->xops || !version)
		return -EINVAL;
	ret = ph->xops->xfer_get_init(ph, 0, 0, 2 * sizeof(value), &transfer);
	if (ret)
		return ret;
	ret = ph->xops->do_xfer(ph, transfer);
	if (!ret) {
		if (transfer->rx.len != sizeof(value)) {
			ret = -EPROTO;
		} else {
			memcpy(&value, transfer->rx.buf, sizeof(value));
			*version = le32_to_cpu(value);
		}
	}
	ph->xops->xfer_put(ph, transfer);
	return ret;
}

struct uke_memlat_probe_ops {
	int (*get)(const struct scmi_protocol_handle *, u32, const void *, size_t, void *, size_t);
	int (*get_c1dcvs_enable)(const struct scmi_protocol_handle *, __le32 *);
};

static const struct uke_memlat_probe_ops uke_memlat_ops = {
	.get = uke_memlat_get,
	.get_c1dcvs_enable = uke_c1dcvs_get_enable,
};

static int uke_memlat_protocol_init(const struct scmi_protocol_handle *ph)
{
	u32 version;
	int ret = uke_cpucp_version_get(ph, &version);

	if (ret)
		return ret;
	dev_info(ph->dev, "Uke CPUCP observed vendor protocol version 0x%x\n", version);
	return version == 0x10000 ? 0 : -EPROTONOSUPPORT;
}

static const struct scmi_protocol uke_memlat_protocol = {
	.id = UKE_MEMLAT_PROTOCOL,
	.owner = THIS_MODULE,
	.instance_init = uke_memlat_protocol_init,
	.ops = &uke_memlat_ops,
	.vendor_id = "Qualcomm",
	.supported_version = 0x10000,
	/* Legacy 0x10 is SET, not a standard version-negotiation message. */
	.no_version_negotiation = true,
};

static int uke_memlat_probe(struct scmi_device *sdev)
{
	const struct uke_memlat_probe_ops *ops;
	struct scmi_protocol_handle *ph;
	__le64 timestamp;
	__le32 request[3], frequency, enabled;
	int ret, i;

	if (!sdev->handle)
		return -EPROBE_DEFER;
	ops = sdev->handle->devm_protocol_get(sdev, UKE_MEMLAT_PROTOCOL, &ph);
	if (IS_ERR(ops)) {
		query_rc = PTR_ERR(ops);
		return query_rc;
	}
	query_rc = ops->get(ph, UKE_MEMLAT_GET_TIMESTAMP, NULL, 0, &timestamp, sizeof(timestamp));
	dev_info(&sdev->dev, "MEMLAT read-only timestamp rc=%d\n", query_rc);
	if (query_rc)
		return 0;
	c1dcvs_rc = ops->get_c1dcvs_enable(ph, &enabled);
	if (!c1dcvs_rc)
		c1dcvs_enabled = le32_to_cpu(enabled);
	dev_info(&sdev->dev, "C1DCVS read-only enable rc=%d enabled=%d\n",
		 c1dcvs_rc, c1dcvs_enabled);
	if (c1dcvs_rc == -ETIMEDOUT)
		return 0;
	for (i = 0; i < 4; i++) {
		request[0] = cpu_to_le32(i);
		request[1] = 0;
		request[2] = 0;
		ret = ops->get(ph, UKE_MEMLAT_GET_FREQ, request, sizeof(request),
			       &frequency, sizeof(frequency));
		dev_info(&sdev->dev, "MEMLAT read-only OEM hw=%d monitor=0 rc=%d frequency=%u\n",
			 i, ret, ret ? 0 : le32_to_cpu(frequency));
		if (ret == -ETIMEDOUT)
			break;
	}
	return 0;
}

static const struct scmi_device_id uke_memlat_ids[] = {
	{ UKE_MEMLAT_PROTOCOL, "uke-cpucp-observe" }, {}
};

static struct scmi_driver uke_memlat_driver = {
	.name = "uke-cpucp-observe",
	.probe = uke_memlat_probe,
	.id_table = uke_memlat_ids,
};

static int __init uke_memlat_init(void)
{
	int ret;

	if (!str_has_prefix(utsname()->release, "7.3.1-") ||
	    !of_machine_is_compatible("xiaomi,uke") ||
	    !of_machine_is_compatible("qcom,sm7675"))
		return -ENODEV;
	ret = scmi_protocol_register(&uke_memlat_protocol);
	if (ret)
		return ret;
	ret = scmi_register(&uke_memlat_driver);
	if (ret)
		scmi_protocol_unregister(&uke_memlat_protocol);
	return ret;
}

static void __exit uke_memlat_exit(void)
{
	scmi_unregister(&uke_memlat_driver);
	scmi_protocol_unregister(&uke_memlat_protocol);
}
module_init(uke_memlat_init);
module_exit(uke_memlat_exit);
MODULE_DESCRIPTION("Manually loaded Uke CPUCP read-only MEMLAT/C1DCVS observer");
MODULE_LICENSE("GPL");
