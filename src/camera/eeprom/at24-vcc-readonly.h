/* SPDX-License-Identifier: GPL-2.0-only */
/* Optional voltage ownership for a read-only at24 consumer; not board data. */
#ifndef AT24_VCC_READONLY_H
#define AT24_VCC_READONLY_H

static int at24_vcc_configure(struct device *dev, struct at24_data *at24, u32 flags)
{
	u32 voltage;
	int ret;

	if (!device_property_present(dev, "vcc-microvolt"))
		return 0;
	if (!(flags & AT24_FLAG_READONLY) ||
	    !device_property_present(dev, "vcc-supply"))
		return -EINVAL;
	ret = device_property_read_u32(dev, "vcc-microvolt", &voltage);
	if (ret)
		return ret;
	if (!voltage || voltage > INT_MAX)
		return -EINVAL;
	at24->vcc_uV = voltage;
	return 0;
}

static int at24_vcc_on(struct at24_data *at24)
{
	int ret, rollback;

	if (!at24->vcc_uV)
		return regulator_enable(at24->vcc_reg);
	ret = READ_ONCE(at24->vcc_fault);
	if (ret)
		return ret;
	ret = regulator_set_voltage(at24->vcc_reg, at24->vcc_uV, at24->vcc_uV);
	if (ret)
		return ret;
	WRITE_ONCE(at24->vcc_voltage_held, true);
	ret = regulator_enable(at24->vcc_reg);
	if (ret) {
		rollback = regulator_set_voltage(at24->vcc_reg, 0, INT_MAX);
		if (rollback)
			WRITE_ONCE(at24->vcc_fault, rollback);
		else
			WRITE_ONCE(at24->vcc_voltage_held, false);
	}
	return ret;
}

static int at24_vcc_off(struct at24_data *at24)
{
	int ret;

	if (at24->vcc_uV && READ_ONCE(at24->vcc_io_active))
		return -EBUSY;
	ret = regulator_disable(at24->vcc_reg);
	if (!at24->vcc_uV)
		return ret;
	if (ret) {
		/* Keep the voltage claim while power-off is uncertain. */
		WRITE_ONCE(at24->vcc_fault, ret);
		return ret;
	}
	if (!at24->vcc_voltage_held)
		return 0;
	ret = regulator_set_voltage(at24->vcc_reg, 0, INT_MAX);
	if (ret) {
		/* Our enable reference is gone. Retain the claim and refuse new I/O. */
		WRITE_ONCE(at24->vcc_fault, ret);
		dev_err(at24_base_client_dev(at24), "VCC voltage withdrawal failed: %d\n", ret);
	} else {
		WRITE_ONCE(at24->vcc_voltage_held, false);
	}
	return 0;
}

static int at24_read(void *priv, unsigned int off, void *val, size_t count)
{
	struct at24_data *at24 = priv;
	struct device *dev = at24_base_client_dev(at24);
	int ret, cleanup;

	if (!count)
		return 0;
	/* Admit the complete range before any voltage, PM or bus operation. */
	if (!val || off > at24->byte_len || count > at24->byte_len - off)
		return -EINVAL;
	if (!at24->vcc_uV)
		return at24_read_data(priv, off, val, count);
	mutex_lock(&at24->vcc_lock);
	ret = READ_ONCE(at24->vcc_fault);
	if (ret)
		goto out;
	WRITE_ONCE(at24->vcc_io_active, true);
	ret = at24_read_data(priv, off, val, count);
	WRITE_ONCE(at24->vcc_io_active, false);
	/* The original read dropped its PM reference. Serialize through suspend. */
	cleanup = pm_runtime_suspend(dev);
	if (!ret) {
		ret = READ_ONCE(at24->vcc_fault);
		if (!ret && cleanup < 0)
			ret = cleanup;
		if (!ret && !pm_runtime_status_suspended(dev))
			ret = -EBUSY;
	}
out:
	mutex_unlock(&at24->vcc_lock);
	return ret;
}

#endif /* AT24_VCC_READONLY_H */
