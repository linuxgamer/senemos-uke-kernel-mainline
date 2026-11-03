// SPDX-License-Identifier: GPL-2.0
// SPI driven IR LED device driver
//
// Copyright (c) 2016 Samsung Electronics Co., Ltd.
// Copyright (c) Andi Shyti <andi@etezian.org>
// Uke adaptation: bounded frames, explicit word order and standard supply.

#include <linux/bits.h>
#include <linux/device.h>
#include <linux/err.h>
#include <linux/math.h>
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/property.h>
#include <linux/regulator/consumer.h>
#include <linux/spi/spi.h>
#include <linux/string.h>
#include <linux/types.h>

#include <media/rc-core.h>

#define IR_SPI_DRIVER_NAME		"ir-spi"

#define IR_SPI_DEFAULT_FREQUENCY	38000
#define IR_SPI_BITS_PER_PULSE		16

struct ir_spi_data {
	u32 freq;
	bool negated;

	u16 pulse;
	u16 space;

	struct rc_dev *rc;
	struct spi_device *spi;
	struct regulator *regulator;
};

static int ir_spi_tx(struct rc_dev *dev, unsigned int *buffer, unsigned int count)
{
	struct ir_spi_data *idata = dev->priv;
	struct spi_transfer xfer = {};
	u64 elapsed = 0, cycles = 0, previous = 0;
	size_t limit, words, offset = 0;
	unsigned int i;
	u16 *tx_buf;
	int ret, power_ret;

	if (!count)
		return -EINVAL;
	/*
	 * Keep a complete frame in one transfer: splitting a pulse train can
	 * introduce arbitrary gaps. Include one inactive word after the frame.
	 */
	limit = min(spi_max_transfer_size(idata->spi),
		    spi_max_message_size(idata->spi));
	limit = min_t(size_t, limit, UINT_MAX);
	for (i = 0; i < count; i++) {
		if (!buffer[i])
			return -EINVAL;
		elapsed += buffer[i];
		if (elapsed > 1000000)
			return -EMSGSIZE;
	}
	cycles = DIV_ROUND_CLOSEST_ULL(elapsed * idata->freq, 1000000);
	if (!cycles || cycles >= limit / sizeof(*tx_buf))
		return -EMSGSIZE;
	words = cycles + 1;
	tx_buf = kmalloc_array(words, sizeof(*tx_buf), GFP_KERNEL);
	if (!tx_buf)
		return -ENOMEM;

	elapsed = 0;
	for (i = 0; i < count; i++) {
		u16 value = i % 2 ? idata->space : idata->pulse;

		elapsed += buffer[i];
		cycles = DIV_ROUND_CLOSEST_ULL(elapsed * idata->freq, 1000000);
		/*
		 * Quantize cumulative edges, not each interval independently.
		 * Never modify the caller's microsecond durations.
		 */
		while (previous < cycles) {
			tx_buf[offset++] = value;
			previous++;
		}
	}
	tx_buf[offset++] = idata->space;
	xfer.speed_hz = idata->freq * IR_SPI_BITS_PER_PULSE;
	xfer.bits_per_word = IR_SPI_BITS_PER_PULSE;
	xfer.len = offset * sizeof(*tx_buf);
	xfer.tx_buf = tx_buf;

	if (idata->regulator) {
		ret = regulator_enable(idata->regulator);
		if (ret)
			goto out;
	}
	ret = spi_sync_transfer(idata->spi, &xfer, 1);
	if (idata->regulator) {
		power_ret = regulator_disable(idata->regulator);
		if (!ret)
			ret = power_ret;
	}
out:
	kfree(tx_buf);
	return ret ? ret : count;
}

static int ir_spi_set_tx_carrier(struct rc_dev *dev, u32 carrier)
{
	struct ir_spi_data *idata = dev->priv;

	if (!carrier || carrier < DIV_ROUND_UP(idata->spi->controller->min_speed_hz,
					     IR_SPI_BITS_PER_PULSE))
		return -EINVAL;

	if (carrier > idata->spi->max_speed_hz / IR_SPI_BITS_PER_PULSE)
		return -EINVAL;

	idata->freq = carrier;

	return 0;
}

static int ir_spi_set_duty_cycle(struct rc_dev *dev, u32 duty_cycle)
{
	struct ir_spi_data *idata = dev->priv;
	unsigned int bits;

	if (!duty_cycle || duty_cycle >= 100)
		return -EINVAL;
	bits = clamp_val(DIV_ROUND_CLOSEST(duty_cycle * 16, 100), 1, 15);

	idata->pulse = GENMASK(bits - 1, 0);

	if (idata->negated) {
		idata->pulse = ~idata->pulse;
		idata->space = 0xffff;
	} else {
		idata->space = 0;
	}

	return 0;
}

static int ir_spi_probe(struct spi_device *spi)
{
	struct device *dev = &spi->dev;
	int ret;
	u8 dc;
	struct ir_spi_data *idata;
	const char *label;

	/* A native u16 pulse must be shifted as a 16-bit word on the wire. */
	spi->bits_per_word = IR_SPI_BITS_PER_PULSE;
	ret = spi_setup(spi);
	if (ret)
		return dev_err_probe(dev, ret, "16-bit IR transfer unsupported\n");

	idata = devm_kzalloc(dev, sizeof(*idata), GFP_KERNEL);
	if (!idata)
		return -ENOMEM;

	idata->regulator = devm_regulator_get_optional(dev, "power");
	if (IS_ERR(idata->regulator)) {
		if (PTR_ERR(idata->regulator) != -ENODEV)
			return dev_err_probe(dev, PTR_ERR(idata->regulator),
					     "IR supply unavailable\n");
		idata->regulator = NULL;
	}

	idata->rc = devm_rc_allocate_device(&spi->dev, RC_DRIVER_IR_RAW_TX);
	if (!idata->rc)
		return -ENOMEM;

	idata->rc->tx_ir           = ir_spi_tx;
	idata->rc->s_tx_carrier    = ir_spi_set_tx_carrier;
	idata->rc->s_tx_duty_cycle = ir_spi_set_duty_cycle;
	idata->rc->device_name	   = "IR SPI";
	if (!device_property_read_string(dev, "label", &label))
		idata->rc->device_name = label;
	idata->rc->driver_name     = IR_SPI_DRIVER_NAME;
	idata->rc->priv            = idata;
	idata->spi                 = spi;

	idata->negated = device_property_read_bool(dev, "led-active-low");
	if (device_property_present(dev, "duty-cycle")) {
		ret = device_property_read_u8(dev, "duty-cycle", &dc);
		if (ret)
			return dev_err_probe(dev, ret, "invalid IR duty property\n");
	} else {
		dc = 50;
	}

	ret = ir_spi_set_duty_cycle(idata->rc, dc);
	if (ret)
		return dev_err_probe(dev, ret, "invalid IR duty cycle\n");
	ret = ir_spi_set_tx_carrier(idata->rc, IR_SPI_DEFAULT_FREQUENCY);
	if (ret)
		return dev_err_probe(dev, ret, "default IR carrier unavailable\n");

	return devm_rc_register_device(dev, idata->rc);
}

static const struct of_device_id ir_spi_of_match[] = {
	{ .compatible = "ir-spi-led" },
	{}
};
MODULE_DEVICE_TABLE(of, ir_spi_of_match);

static const struct spi_device_id ir_spi_ids[] = {
	{ "ir-spi-led" },
	{}
};
MODULE_DEVICE_TABLE(spi, ir_spi_ids);

static struct spi_driver ir_spi_driver = {
	.probe = ir_spi_probe,
	.id_table = ir_spi_ids,
	.driver = {
		.name = IR_SPI_DRIVER_NAME,
		.of_match_table = ir_spi_of_match,
	},
};
module_spi_driver(ir_spi_driver);

MODULE_AUTHOR("Andi Shyti <andi@etezian.org>");
MODULE_DESCRIPTION("SPI IR LED");
MODULE_LICENSE("GPL v2");
