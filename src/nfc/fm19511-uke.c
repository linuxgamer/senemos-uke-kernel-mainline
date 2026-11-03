// SPDX-License-Identifier: GPL-2.0-only
/* FM19511 transport/configuration from MiCode Uke 5712080a (Linux Foundation). */
#include <linux/delay.h>
#include <linux/compat.h>
#include <linux/i2c.h>
#include <linux/interrupt.h>
#include <linux/kref.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/poll.h>
#include <linux/pm.h>
#include <linux/pm_wakeirq.h>
#include <linux/pm_wakeup.h>
#include <linux/property.h>
#include <linux/regulator/consumer.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/uaccess.h>
#include <linux/workqueue.h>
#include "fm19511-uapi.h"

#define FM19511_LIMIT 256

struct fm19511 {
	struct i2c_client *client;
	struct miscdevice misc;
	struct mutex lock;
	struct kref refs;
	struct delayed_work clear_irq;
	wait_queue_head_t wait;
	atomic_t event;
	atomic64_t irq_sequence;
	u64 status_sequence;
	u8 irq_status[3];
	bool opened;
	bool suspended;
	int fault;
};

static int fm19511_read_reg(struct fm19511 *tag, u16 address, u8 *value)
{
	char command[] = { address >> 8, address & 0xff };
	int ret = i2c_master_send(tag->client, command, sizeof(command));

	if (ret != sizeof(command))
		return ret < 0 ? ret : -EIO;
	ret = i2c_master_recv(tag->client, (char *)value, 1);
	return ret == 1 ? 0 : ret < 0 ? ret : -EIO;
}

static int fm19511_write_reg(struct fm19511 *tag, u16 address, u8 value)
{
	char command[] = { address >> 8, address & 0xff, value };
	int ret = i2c_master_send(tag->client, command, sizeof(command));

	return ret == sizeof(command) ? 0 : ret < 0 ? ret : -EIO;
}

static int fm19511_configure(struct fm19511 *tag)
{
	static const struct { u16 address; u8 value; } config[] = {
		{ 0xffe1, 0x09 }, { 0xfffa, 0x3e },
		{ 0xfffc, 0xbf }, { 0xfffd, 0x02 },
	};
	u8 previous[ARRAY_SIZE(config)], value;
	unsigned int i, changed = 0;
	int ret;

	ret = fm19511_read_reg(tag, 0xffff, &value);
	if (ret)
		return ret;
	for (i = 0; i < ARRAY_SIZE(config); i++) {
		ret = fm19511_read_reg(tag, config[i].address, &previous[i]);
		if (ret)
			return ret;
	}
	for (i = 0; i < ARRAY_SIZE(config); i++) {
		changed = i + 1;
		ret = fm19511_write_reg(tag, config[i].address, config[i].value);
		if (ret)
			break;
		ret = fm19511_read_reg(tag, config[i].address, &value);
		if (ret || value != config[i].value) {
			ret = ret ? ret : -EIO;
			break;
		}
	}
	if (!ret)
		return 0;
	/* Restore volatile settings only; probe never programs EEPROM or NDEF. */
	while (changed--) {
		int restore = fm19511_write_reg(tag, config[changed].address, previous[changed]);

		if (restore)
			dev_warn(&tag->client->dev, "volatile configuration restore failed: %d\n", restore);
	}
	return ret;
}

static void fm19511_free(struct kref *refs)
{
	kfree(container_of(refs, struct fm19511, refs));
}

static int fm19511_open(struct inode *inode, struct file *file)
{
	struct fm19511 *tag = container_of(file->private_data, struct fm19511, misc);
	int ret = 0;

	mutex_lock(&tag->lock);
	if (!tag->client)
		ret = -ENODEV;
	else if (tag->opened)
		ret = -EBUSY;
	else {
		tag->opened = true;
		kref_get(&tag->refs);
		file->private_data = tag;
	}
	mutex_unlock(&tag->lock);
	return ret ? ret : nonseekable_open(inode, file);
}

static int fm19511_release(struct inode *inode, struct file *file)
{
	struct fm19511 *tag = file->private_data;

	mutex_lock(&tag->lock);
	tag->opened = false;
	mutex_unlock(&tag->lock);
	kref_put(&tag->refs, fm19511_free);
	return 0;
}

static ssize_t fm19511_read(struct file *file, char __user *data,
			    size_t count, loff_t *position)
{
	struct fm19511 *tag = file->private_data;
	char buffer[FM19511_LIMIT];
	int ret, event;

	if (!count)
		return 0;
	if (count > sizeof(buffer))
		return -EMSGSIZE;
	mutex_lock(&tag->lock);
	event = atomic_xchg(&tag->event, 0);
	ret = !tag->client ? -ENODEV : tag->suspended ? -EHOSTDOWN :
		i2c_master_recv(tag->client, buffer, count);
	if (ret >= 0 && ret != count)
		ret = -EIO;
	if (ret > 0) {
		if (copy_to_user(data, buffer, ret))
			ret = -EFAULT;
	}
	if (ret <= 0 && event)
		atomic_set(&tag->event, 1);
	mutex_unlock(&tag->lock);
	return ret;
}

static ssize_t fm19511_write(struct file *file, const char __user *data,
			     size_t count, loff_t *position)
{
	struct fm19511 *tag = file->private_data;
	char buffer[FM19511_LIMIT];
	int ret;

	if (!count)
		return 0;
	if (count > sizeof(buffer))
		return -EMSGSIZE;
	/* Address selection is not an EEPROM write. Never accept payload bytes. */
	if (count != 2)
		return -EROFS;
	if (copy_from_user(buffer, data, count))
		return -EFAULT;
	mutex_lock(&tag->lock);
	ret = !tag->client ? -ENODEV : tag->suspended ? -EHOSTDOWN :
		i2c_master_send(tag->client, buffer, count);
	if (ret >= 0 && ret != count)
		ret = -EIO;
	mutex_unlock(&tag->lock);
	return ret;
}

static __poll_t fm19511_poll(struct file *file, poll_table *table)
{
	struct fm19511 *tag = file->private_data;
	__poll_t result = 0;

	poll_wait(file, &tag->wait, table);
	mutex_lock(&tag->lock);
	if (!tag->client)
		result = EPOLLERR | EPOLLHUP;
	else if (tag->fault)
		result = EPOLLERR;
	else if (atomic_read(&tag->event))
		result = EPOLLIN | EPOLLRDNORM;
	mutex_unlock(&tag->lock);
	return result;
}

static long fm19511_ioctl(struct file *file, unsigned int command,
			  unsigned long argument)
{
	struct fm19511 *tag = file->private_data;
	void __user *user = (void __user *)argument;
	struct fm19511_memory memory = {};
	struct fm19511_events events = {};
	struct fm19511_info info = {
		.abi_version = FM19511_ABI_VERSION,
		.capabilities = FM19511_CAP_TYPE2_TAG | FM19511_CAP_MEMORY_READ |
				FM19511_CAP_RF_EVENTS,
		.max_transfer = FM19511_MAX_TRANSFER,
	};
	char address[2];
	int ret = 0, event;

	if (command != FM19511_IOC_INFO && command != FM19511_IOC_EVENTS &&
	    command != FM19511_IOC_READ_MEMORY)
		return -ENOTTY;
	if (command == FM19511_IOC_READ_MEMORY) {
		if (copy_from_user(&memory, user, sizeof(memory)))
			return -EFAULT;
		if (memory.reserved || !memory.length ||
		    memory.length > sizeof(memory.data) ||
		    (u32)memory.address + memory.length > 0x10000)
			return -EINVAL;
		memset(memory.data, 0, sizeof(memory.data));
	}
	mutex_lock(&tag->lock);
	if (!tag->client) {
		ret = -ENODEV;
		goto unlock;
	}
	switch (command) {
	case FM19511_IOC_INFO:
		if (device_can_wakeup(&tag->client->dev))
			info.capabilities |= FM19511_CAP_WAKEUP;
		if (copy_to_user(user, &info, sizeof(info)))
			ret = -EFAULT;
		break;
	case FM19511_IOC_EVENTS:
		/* Consume only the event observed before copying; retain new IRQs. */
		event = atomic_xchg(&tag->event, 0);
		events.irq_sequence = atomic64_read(&tag->irq_sequence);
		events.status_sequence = tag->status_sequence;
		events.error = tag->fault;
		events.main_irq = tag->irq_status[0];
		events.fifo_irq = tag->irq_status[1];
		events.aux_irq = tag->irq_status[2];
		events.pending = !!event;
		if (copy_to_user(user, &events, sizeof(events))) {
			if (event)
				atomic_set(&tag->event, 1);
			ret = -EFAULT;
		}
		break;
	case FM19511_IOC_READ_MEMORY:
		if (tag->suspended) {
			ret = -EHOSTDOWN;
			break;
		}
		address[0] = memory.address >> 8;
		address[1] = memory.address & 0xff;
		ret = i2c_master_send(tag->client, address, sizeof(address));
		if (ret != sizeof(address)) {
			ret = ret < 0 ? ret : -EIO;
			break;
		}
		ret = i2c_master_recv(tag->client, (char *)memory.data, memory.length);
		if (ret != memory.length) {
			ret = ret < 0 ? ret : -EIO;
			break;
		}
		ret = copy_to_user(user, &memory, sizeof(memory)) ? -EFAULT : 0;
		break;
	}
unlock:
	mutex_unlock(&tag->lock);
	return ret;
}

static const struct file_operations fm19511_fops = {
	.owner = THIS_MODULE, .open = fm19511_open, .release = fm19511_release,
	.read = fm19511_read, .write = fm19511_write, .poll = fm19511_poll,
	.unlocked_ioctl = fm19511_ioctl,
#ifdef CONFIG_COMPAT
	.compat_ioctl = compat_ptr_ioctl,
#endif
};

static void fm19511_clear_irq(struct work_struct *work)
{
	struct fm19511 *tag = container_of(to_delayed_work(work), struct fm19511, clear_irq);
	u8 status[3];
	int ret = 0;
	u64 sequence;
	unsigned int i;

	mutex_lock(&tag->lock);
	sequence = atomic64_read(&tag->irq_sequence);
	if (tag->client && !tag->suspended) {
		for (i = 0; i < ARRAY_SIZE(status); i++) {
			ret = fm19511_read_reg(tag, 0xfff7 + i, &status[i]);
			if (ret)
				break;
		}
		if (!ret) {
			memcpy(tag->irq_status, status, sizeof(status));
			tag->status_sequence = sequence;
		}
		tag->fault = ret;
		/* Status completion is independently readable after the IRQ edge. */
		atomic_set(&tag->event, 1);
	}
	mutex_unlock(&tag->lock);
	wake_up_interruptible(&tag->wait);
}

static irqreturn_t fm19511_irq(int irq, void *data)
{
	struct fm19511 *tag = data;

	atomic64_inc(&tag->irq_sequence);
	atomic_set(&tag->event, 1);
	pm_wakeup_event(&tag->client->dev, 2000);
	wake_up_interruptible(&tag->wait);
	/* Retain the OEM RF transaction settling interval before IRQ clear. */
	if (!READ_ONCE(tag->suspended))
		mod_delayed_work(system_wq, &tag->clear_irq, msecs_to_jiffies(150));
	return IRQ_HANDLED;
}

static void fm19511_power_off(void *regulator)
{
	regulator_disable(regulator);
}

static int fm19511_probe(struct i2c_client *client)
{
	struct regulator *supply;
	struct fm19511 *tag;
	const char *model;
	int ret;

	if (!of_machine_is_compatible("xiaomi,uke") ||
	    !of_machine_is_compatible("qcom,sm7675") ||
	    of_property_read_string(of_root, "model", &model) || strcmp(model, "POCO Pad X1"))
		return -ENODEV;
	if (!i2c_check_functionality(client->adapter, I2C_FUNC_I2C) || client->irq <= 0)
		return -ENODEV;
	supply = devm_regulator_get(&client->dev, "vdd");
	if (IS_ERR(supply))
		return dev_err_probe(&client->dev, PTR_ERR(supply), "tag supply unavailable\n");
	ret = regulator_set_voltage(supply, 3300000, 3300000);
	if (ret)
		return ret;
	ret = regulator_enable(supply);
	if (ret)
		return ret;
	ret = devm_add_action_or_reset(&client->dev, fm19511_power_off, supply);
	if (ret)
		return ret;
	tag = kzalloc(sizeof(*tag), GFP_KERNEL);
	if (!tag)
		return -ENOMEM;
	tag->client = client;
	mutex_init(&tag->lock);
	kref_init(&tag->refs);
	init_waitqueue_head(&tag->wait);
	atomic_set(&tag->event, 0);
	atomic64_set(&tag->irq_sequence, 0);
	INIT_DELAYED_WORK(&tag->clear_irq, fm19511_clear_irq);
	usleep_range(5000, 5100);
	ret = fm19511_configure(tag);
	if (ret)
		goto free;
	ret = request_irq(client->irq, fm19511_irq, IRQF_TRIGGER_FALLING,
			  "fm19511-uke", tag);
	if (ret)
		goto free;
	tag->misc = (struct miscdevice) {
		.minor = MISC_DYNAMIC_MINOR, .name = "fm-ntag",
		.fops = &fm19511_fops, .parent = &client->dev, .mode = 0600,
	};
	i2c_set_clientdata(client, tag);
	ret = device_init_wakeup(&client->dev,
				 device_property_read_bool(&client->dev, "wakeup-source"));
	if (ret)
		goto free_irq;
	if (device_can_wakeup(&client->dev)) {
		ret = dev_pm_set_wake_irq(&client->dev, client->irq);
		if (ret) {
			device_init_wakeup(&client->dev, false);
			goto free_irq;
		}
	}
	ret = misc_register(&tag->misc);
	if (ret) {
		dev_pm_clear_wake_irq(&client->dev);
		device_init_wakeup(&client->dev, false);
		goto free_irq;
	}
	return 0;
free_irq:
	free_irq(client->irq, tag);
	cancel_delayed_work_sync(&tag->clear_irq);
free:
	kref_put(&tag->refs, fm19511_free);
	return ret;
}

static void fm19511_remove(struct i2c_client *client)
{
	struct fm19511 *tag = i2c_get_clientdata(client);

	misc_deregister(&tag->misc);
	dev_pm_clear_wake_irq(&client->dev);
	device_init_wakeup(&client->dev, false);
	free_irq(client->irq, tag);
	cancel_delayed_work_sync(&tag->clear_irq);
	mutex_lock(&tag->lock);
	tag->client = NULL;
	mutex_unlock(&tag->lock);
	wake_up_interruptible(&tag->wait);
	kref_put(&tag->refs, fm19511_free);
}

static int fm19511_suspend(struct device *dev)
{
	struct fm19511 *tag = i2c_get_clientdata(to_i2c_client(dev));

	mutex_lock(&tag->lock);
	tag->suspended = true;
	mutex_unlock(&tag->lock);
	cancel_delayed_work_sync(&tag->clear_irq);
	return 0;
}

static int fm19511_resume(struct device *dev)
{
	struct fm19511 *tag = i2c_get_clientdata(to_i2c_client(dev));

	mutex_lock(&tag->lock);
	tag->suspended = false;
	mutex_unlock(&tag->lock);
	/* Drain a latched status after sleep; retain the rail and EEPROM contents. */
	mod_delayed_work(system_wq, &tag->clear_irq, msecs_to_jiffies(150));
	return 0;
}

static DEFINE_SIMPLE_DEV_PM_OPS(fm19511_pm_ops, fm19511_suspend, fm19511_resume);

static const struct of_device_id fm19511_match[] = {
	{ .compatible = "fm,fm19511" }, {}
};
MODULE_DEVICE_TABLE(of, fm19511_match);

static struct i2c_driver fm19511_driver = {
	.driver = { .name = "fm19511-uke", .of_match_table = fm19511_match,
		    .pm = pm_sleep_ptr(&fm19511_pm_ops) },
	.probe = fm19511_probe, .remove = fm19511_remove,
};
module_i2c_driver(fm19511_driver);
MODULE_DESCRIPTION("POCO Pad X1 FM19511 NFC tag transport");
MODULE_LICENSE("GPL");
