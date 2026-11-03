// SPDX-License-Identifier: GPL-2.0-only
/* Own request lifetime; the existing QCOM flash driver owns electrical control. */
#include <linux/compat.h>
#include <linux/device/driver.h>
#include <linux/fs.h>
#include <linux/kref.h>
#include <linux/leds.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/reboot.h>
#include <linux/slab.h>
#include <linux/suspend.h>
#include <linux/uaccess.h>
#include "uke-torch-uapi.h"

struct uke_torch {
	struct kref ref;
	struct mutex lock;
	struct led_classdev *led;
	struct miscdevice misc;
	struct notifier_block pm_notifier, reboot_notifier;
	u32 requested_percent, brightness;
	int last_io_error;
	bool brightness_valid, writer_open, suspended, dead, active;
};

static void free_torch(struct kref *ref)
{
	kfree(container_of(ref, struct uke_torch, ref));
}

static int torch_output(struct uke_torch *torch, u32 brightness)
{
	int ret = led_set_brightness_sync(torch->led, brightness);

	torch->brightness_valid = !ret;
	if (!ret)
		torch->brightness = brightness;
	torch->last_io_error = ret;
	return ret;
}

static int torch_apply(struct uke_torch *torch, u32 percent)
{
	/* Match Nabu's percentage scaling without increasing Uke's current ceiling. */
	u32 brightness = (percent * torch->led->max_brightness + 99) / 100;
	int ret = torch_output(torch, brightness);

	if (ret) {
		/* Retain the original error even if the best-effort off succeeds. */
		torch_output(torch, LED_OFF);
		torch->last_io_error = ret;
	}
	return ret;
}

static int torch_open(struct inode *inode, struct file *file)
{
	struct uke_torch *torch = container_of(file->private_data, struct uke_torch, misc);
	int ret = -ENODEV;

	mutex_lock(&torch->lock);
	if (torch->dead || !torch->active)
		goto out;
	if ((file->f_mode & FMODE_WRITE) && torch->writer_open) {
		ret = -EBUSY;
		goto out;
	}
	if (file->f_mode & FMODE_WRITE) {
		ret = torch_apply(torch, 0);
		if (ret)
			goto out;
	}
	if (!kref_get_unless_zero(&torch->ref)) {
		ret = -ENODEV;
		goto out;
	}
	ret = nonseekable_open(inode, file);
	if (ret) {
		kref_put(&torch->ref, free_torch);
		goto out;
	}
	file->private_data = torch;
	if (file->f_mode & FMODE_WRITE) {
		torch->writer_open = true;
		torch->requested_percent = 100;
	}
 out:
	mutex_unlock(&torch->lock);
	return ret;
}

static int torch_release(struct inode *inode, struct file *file)
{
	struct uke_torch *torch = file->private_data;

	mutex_lock(&torch->lock);
	if (file->f_mode & FMODE_WRITE) {
		if (!torch->dead)
			torch_apply(torch, 0);
		torch->writer_open = false;
		torch->requested_percent = 100;
	}
	mutex_unlock(&torch->lock);
	kref_put(&torch->ref, free_torch);
	return 0;
}

static long torch_ioctl(struct file *file, unsigned int command, unsigned long arg)
{
	struct uke_torch *torch = file->private_data;
	struct uke_torch_request request = {};
	struct uke_torch_status status = {};
	u32 percent;
	int ret = 0;

	if (command != UKE_TORCH_STATUS && command != UKE_TORCH_SET && command != UKE_TORCH_ENABLE)
		return -ENOTTY;
	if (!(file->f_mode & (command == UKE_TORCH_STATUS ? FMODE_READ : FMODE_WRITE)))
		return -EBADF;
	if (command != UKE_TORCH_STATUS) {
		if (copy_from_user(&request, (void __user *)arg, sizeof(request)))
			return -EFAULT;
		if (request.abi != UKE_TORCH_ABI || request.reserved[0] || request.reserved[1] ||
		    request.value > (command == UKE_TORCH_SET ? 100 : 1))
			return -EINVAL;
	}
	mutex_lock(&torch->lock);
	if (torch->dead) {
		ret = -ENODEV;
		goto out;
	}
	if (command == UKE_TORCH_STATUS) {
		status.abi = UKE_TORCH_ABI;
		status.requested_percent = torch->requested_percent;
		status.brightness = torch->brightness;
		status.brightness_valid = torch->brightness_valid;
		status.max_microamp = UKE_TORCH_MAX_UA;
		status.suspended = torch->suspended;
		status.last_io_error = torch->last_io_error;
		goto out;
	}
	percent = command == UKE_TORCH_SET ? request.value :
		(request.value ? torch->requested_percent : 0);
	if (torch->suspended && percent) {
		ret = -EBUSY;
		goto out;
	}
	ret = torch_apply(torch, percent);
	if (!ret && command == UKE_TORCH_SET && percent)
		torch->requested_percent = percent;
 out:
	mutex_unlock(&torch->lock);
	if (!ret && command == UKE_TORCH_STATUS && copy_to_user((void __user *)arg, &status, sizeof(status)))
		ret = -EFAULT;
	return ret;
}

static const struct file_operations torch_fops = {
	.owner = THIS_MODULE, .open = torch_open, .release = torch_release,
	.unlocked_ioctl = torch_ioctl, .compat_ioctl = compat_ptr_ioctl,
};

static int torch_power_event(struct notifier_block *nb, unsigned long event, void *data)
{
	struct uke_torch *torch = container_of(nb, struct uke_torch, pm_notifier);
	int ret = 0;

	mutex_lock(&torch->lock);
	if (!torch->active || torch->dead)
		goto out;
	if (event == PM_SUSPEND_PREPARE || event == PM_HIBERNATION_PREPARE || event == PM_RESTORE_PREPARE) {
		torch->suspended = true;
		ret = torch_apply(torch, 0);
	} else if (event == PM_POST_SUSPEND || event == PM_POST_HIBERNATION || event == PM_POST_RESTORE) {
		/* Resume never restores an earlier on request. */
		torch->suspended = false;
	}
 out:
	mutex_unlock(&torch->lock);
	return notifier_from_errno(ret);
}

static int torch_shutdown_event(struct notifier_block *nb, unsigned long event, void *data)
{
	struct uke_torch *torch = container_of(nb, struct uke_torch, reboot_notifier);

	mutex_lock(&torch->lock);
	if (torch->active && !torch->dead) {
		torch->dead = true;
		torch_apply(torch, 0);
	}
	mutex_unlock(&torch->lock);
	return NOTIFY_DONE;
}

static bool torch_supplier_valid(struct platform_device *pdev, struct led_classdev *led)
{
	struct device_node *node, *parent;
	u32 channels[2], current_ua, reg;
	bool valid;

	if (strcmp(dev_name(led->dev), "uke:white:torch") || led->max_brightness != 2 ||
	    (led->flags & LED_DEV_CAP_FLASH) || !led->dev->parent->driver ||
	    strcmp(led->dev->parent->driver->name, "leds-qcom-flash"))
		return false;
	node = of_parse_phandle(pdev->dev.of_node, "leds", 0);
	parent = of_get_parent(node);
	valid = node && parent && of_device_is_compatible(parent, "qcom,spmi-flash-led") &&
		!of_property_read_u32(parent, "reg", &reg) && reg == 0xee00 &&
		of_property_count_u32_elems(node, "led-sources") == 2 &&
		!of_property_read_u32_array(node, "led-sources", channels, 2) && channels[0] == 1 && channels[1] == 4 &&
		!of_property_read_u32(node, "led-max-microamp", &current_ua) && current_ua == UKE_TORCH_MAX_UA &&
		!of_property_present(node, "flash-max-microamp");
	of_node_put(parent);
	of_node_put(node);
	return valid;
}

static int torch_probe(struct platform_device *pdev)
{
	struct led_classdev *led;
	struct uke_torch *torch;
	int ret;

	if (!of_machine_is_compatible("xiaomi,uke") || !of_machine_is_compatible("qcom,sm7675"))
		return -ENODEV;
	led = devm_of_led_get(&pdev->dev, 0);
	if (IS_ERR(led))
		return dev_err_probe(&pdev->dev, PTR_ERR(led), "Torch supplier unavailable\n");
	if (!torch_supplier_valid(pdev, led))
		return -ENODEV;
	if (!device_link_add(&pdev->dev, led->dev->parent, DL_FLAG_AUTOREMOVE_CONSUMER))
		return -ENOMEM;
	torch = kzalloc(sizeof(*torch), GFP_KERNEL);
	if (!torch)
		return -ENOMEM;
	kref_init(&torch->ref);
	mutex_init(&torch->lock);
	torch->led = led;
	torch->requested_percent = 100;
	torch->pm_notifier.notifier_call = torch_power_event;
	torch->reboot_notifier.notifier_call = torch_shutdown_event;
	ret = register_pm_notifier(&torch->pm_notifier);
	if (ret)
		goto free;
	ret = register_reboot_notifier(&torch->reboot_notifier);
	if (ret)
		goto unreg_pm;
	mutex_lock(&led->led_access);
	if (led_sysfs_is_disabled(led)) {
		ret = -EBUSY;
		mutex_unlock(&led->led_access);
		goto unreg_reboot;
	}
	led_sysfs_disable(led);
	led_trigger_remove(led);
	ret = torch_apply(torch, 0);
	mutex_unlock(&led->led_access);
	if (ret)
		goto enable_sysfs;
	mutex_lock(&torch->lock);
	torch->active = true;
	mutex_unlock(&torch->lock);
	torch->misc = (struct miscdevice){ .minor = MISC_DYNAMIC_MINOR, .name = "uke-torch",
		.fops = &torch_fops, .parent = &pdev->dev, .mode = 0600 };
	ret = misc_register(&torch->misc);
	if (ret)
		goto enable_sysfs;
	platform_set_drvdata(pdev, torch);
	return 0;
 enable_sysfs:
	mutex_lock(&torch->lock);
	torch->dead = true;
	torch_apply(torch, 0);
	mutex_unlock(&torch->lock);
	mutex_lock(&led->led_access);
	led_sysfs_enable(led);
	mutex_unlock(&led->led_access);
 unreg_reboot:
	unregister_reboot_notifier(&torch->reboot_notifier);
 unreg_pm:
	unregister_pm_notifier(&torch->pm_notifier);
 free:
	kref_put(&torch->ref, free_torch);
	return ret;
}

static void torch_remove(struct platform_device *pdev)
{
	struct uke_torch *torch = platform_get_drvdata(pdev);
	struct led_classdev *led = torch->led;

	mutex_lock(&torch->lock);
	torch->dead = true;
	torch_apply(torch, 0);
	mutex_unlock(&torch->lock);
	misc_deregister(&torch->misc);
	unregister_pm_notifier(&torch->pm_notifier);
	unregister_reboot_notifier(&torch->reboot_notifier);
	mutex_lock(&led->led_access);
	led_sysfs_enable(led);
	mutex_unlock(&led->led_access);
	kref_put(&torch->ref, free_torch);
}

static const struct of_device_id torch_match[] = {
	{ .compatible = "senemos,uke-torch" }, {}
};
MODULE_DEVICE_TABLE(of, torch_match);
static struct platform_driver torch_driver = {
	.probe = torch_probe, .remove = torch_remove,
	.driver = { .name = "uke-torch", .of_match_table = torch_match },
};
module_platform_driver(torch_driver);
MODULE_DESCRIPTION("Uke torch request ownership and lifecycle");
MODULE_LICENSE("GPL");
