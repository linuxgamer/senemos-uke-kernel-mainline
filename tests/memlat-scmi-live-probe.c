// SPDX-License-Identifier: GPL-2.0-only
/* Copyright (c) 2022 Qualcomm Innovation Center, Inc. All rights reserved.
 * Read-only diagnostic for the exact Uke OEM MEMLAT GET wire contract.
 * Qualcomm protocol source: MiCode 5712080a and July 2026 RFC patch 03/10.
 * No configuration, start, stop, log flush or persistent driver is installed.
 */
#include <linux/module.h>
#include <linux/of.h>
#include <linux/scmi_protocol.h>
#include <linux/utsname.h>
#include "protocols.h"

#define UKE_MEMLAT_PROTOCOL 0x80
#define UKE_MEMLAT_ALGO 0x4d454d4c4154ULL
#define UKE_MEMLAT_GET_FREQ 35
#define UKE_MEMLAT_GET_TIMESTAMP 38

struct uke_memlat_header {
	__le32 reserved, algo_low, algo_high, parameter;
};

static int query_rc = -EINPROGRESS;
module_param(query_rc, int, 0444);
MODULE_PARM_DESC(query_rc, "First timestamp GET result; zero is not policy acceptance");

static int uke_memlat_get(const struct scmi_protocol_handle *ph, u32 parameter,
			 const void *request, size_t tx_len, void *reply, size_t rx_len)
{
	struct uke_memlat_header *header;
	struct scmi_xfer *transfer;
	int ret;

	if (!ph || !ph->xops || !reply ||
	    !((parameter == UKE_MEMLAT_GET_TIMESTAMP && !tx_len && rx_len == 8) ||
	      (parameter == UKE_MEMLAT_GET_FREQ && request && tx_len == 12 && rx_len == 4)))
		return -EINVAL;
	/* shmem_fetch_response() clips to capacity; retain an overlength sentinel. */
	ret = ph->xops->xfer_get_init(ph, 0x11, sizeof(*header) + tx_len,
				      rx_len + sizeof(__le32), &transfer);
	if (ret)
		return ret;
	header = transfer->tx.buf;
	header->reserved = 0;
	header->algo_low = cpu_to_le32(lower_32_bits(UKE_MEMLAT_ALGO));
	header->algo_high = cpu_to_le32(upper_32_bits(UKE_MEMLAT_ALGO));
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

struct uke_memlat_probe_ops {
	int (*get)(const struct scmi_protocol_handle *, u32, const void *, size_t, void *, size_t);
};

static const struct uke_memlat_probe_ops uke_memlat_ops = { .get = uke_memlat_get };

static int uke_memlat_protocol_init(const struct scmi_protocol_handle *ph)
{
	dev_info(ph->dev, "Uke read-only MEMLAT protocol version 0x%x\n", ph->version);
	return ph->version == 0x10000 ? 0 : -EPROTONOSUPPORT;
}

static const struct scmi_protocol uke_memlat_protocol = {
	.id = UKE_MEMLAT_PROTOCOL,
	.owner = THIS_MODULE,
	.instance_init = uke_memlat_protocol_init,
	.ops = &uke_memlat_ops,
	.vendor_id = "Qualcomm",
	.supported_version = 0x10000,
};

static int uke_memlat_probe(struct scmi_device *sdev)
{
	const struct uke_memlat_probe_ops *ops;
	struct scmi_protocol_handle *ph;
	__le64 timestamp;
	__le32 request[3], frequency;
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
	{ UKE_MEMLAT_PROTOCOL, "uke-memlat-read-only-probe" }, {}
};

static struct scmi_driver uke_memlat_driver = {
	.name = "uke-memlat-read-only-probe",
	.probe = uke_memlat_probe,
	.id_table = uke_memlat_ids,
};

static int __init uke_memlat_init(void)
{
	int ret;

	if (strcmp(utsname()->release, "7.3.0-36") ||
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
MODULE_DESCRIPTION("Uke release-36 read-only MEMLAT protocol diagnostic");
MODULE_LICENSE("GPL");
