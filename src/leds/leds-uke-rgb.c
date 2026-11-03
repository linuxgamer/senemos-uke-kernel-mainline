// SPDX-License-Identifier: GPL-2.0-only
/* Uke notification policy; original QCOM LPG retains all electrical control. */
#include <linux/compat.h>
#include <linux/device/driver.h>
#include <linux/fs.h>
#include <linux/jiffies.h>
#include <linux/kref.h>
#include <linux/led-class-multicolor.h>
#include <linux/leds.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/notifier.h>
#include <linux/of.h>
#include <linux/overflow.h>
#include <linux/platform_device.h>
#include <linux/power_supply.h>
#include <linux/reboot.h>
#include <linux/slab.h>
#include <linux/suspend.h>
#include <linux/timekeeping.h>
#include <linux/uaccess.h>
#include <linux/uke-rgb.h>
#include <linux/workqueue.h>
#include <dt-bindings/leds/common.h>
#include "uke-rgb-policy.h"

struct uke_rgb {
	struct kref ref;
	struct mutex lock;
	struct led_classdev *led;
	struct led_classdev_mc *mc;
	struct miscdevice misc;
	struct delayed_work pattern_work, battery_work;
	struct notifier_block battery_notifier, pm_notifier, reboot_notifier;
	enum uke_rgb_mode battery_mode, mode;
	u64 epoch_ms, test_until_ms;
	u32 manual_rgb, manual_percent, effective_rgb, effective_brightness;
	int battery_soc, last_io_error;
	bool manual, battery_valid, camera, camera_seen, suspended, dead, active, writer_open;
};
static DEFINE_MUTEX(controller_lock);
static struct uke_rgb *controller;
static u64 now_ms(void) { return ktime_to_ms(ktime_get_boottime()); }
static void free_rgb(struct kref *ref) { kfree(container_of(ref, struct uke_rgb, ref)); }

/* Only the policy worker writes color; all competing sysfs stores are disabled. */
static int output(struct uke_rgb *rgb, struct uke_rgb_frame frame)
{
	int i, ret;

	for (i = 0; i < rgb->mc->num_colors; i++) {
		u32 color = rgb->mc->subled_info[i].color_index;
		u32 value = color == LED_COLOR_ID_RED ? frame.rgb >> 16 :
			color == LED_COLOR_ID_GREEN ? (frame.rgb >> 8) & 255 : frame.rgb & 255;
		rgb->mc->subled_info[i].intensity = value * 511 / 255;
	}
	ret = led_set_brightness_sync(rgb->led, min_t(u32, frame.brightness, UKE_RGB_LIMIT));
	if (!ret) {
		rgb->effective_rgb = frame.rgb;
		rgb->effective_brightness = frame.brightness;
	}
	rgb->last_io_error = ret;
	return ret;
}
static enum uke_rgb_mode selected(struct uke_rgb *rgb, u64 now)
{
	return uke_rgb_select(rgb->camera, now < rgb->test_until_ms,
			      rgb->battery_mode, rgb->manual);
}
static void pattern_work(struct work_struct *work)
{
	struct uke_rgb *rgb = container_of(to_delayed_work(work), struct uke_rgb, pattern_work);
	struct uke_rgb_frame frame;
	enum uke_rgb_mode mode;
	u64 now;

	mutex_lock(&rgb->lock);
	if (rgb->dead || rgb->suspended)
		goto out;
	now = now_ms();
	mode = selected(rgb, now);
	if (mode != rgb->mode) {
		rgb->mode = mode;
		rgb->epoch_ms = now;
	}
	frame = uke_rgb_frame(mode, mode == UKE_RGB_TEST ?
			     now - (rgb->test_until_ms - UKE_RGB_TEST_MS) : now - rgb->epoch_ms, rgb->manual_rgb,
			     rgb->manual_percent ? max_t(u32, 1, rgb->manual_percent * UKE_RGB_LIMIT / 100) : 0);
	if (frame.rgb != rgb->effective_rgb || frame.brightness != rgb->effective_brightness) {
		if (output(rgb, frame)) {
			if (!led_set_brightness_sync(rgb->led, LED_OFF))
				rgb->effective_brightness = 0;
			frame.delay_ms = 1000;
		}
	}
	if (mode == UKE_RGB_TEST)
		frame.delay_ms = min_t(u64, frame.delay_ms, rgb->test_until_ms - now);
	mod_delayed_work(system_freezable_wq, &rgb->pattern_work,
			 max_t(unsigned long, 1, msecs_to_jiffies(frame.delay_ms)));
 out:
	mutex_unlock(&rgb->lock);
}
static void battery_work(struct work_struct *work)
{
	struct uke_rgb *rgb = container_of(to_delayed_work(work), struct uke_rgb, battery_work);
	struct power_supply *supply;
	union power_supply_propval value = {};
	int ret = -ENODEV;

	if (READ_ONCE(rgb->dead))
		return;
	supply = power_supply_get_by_name("qcom-battmgr-bat");
	if (supply) {
		if (supply->desc->type == POWER_SUPPLY_TYPE_BATTERY)
			ret = power_supply_get_property(supply, POWER_SUPPLY_PROP_CAPACITY, &value);
		power_supply_put(supply);
	}
	mutex_lock(&rgb->lock);
	if (!rgb->dead) {
		rgb->battery_valid = !ret && value.intval >= 0 && value.intval <= 100;
		if (rgb->battery_valid) {
			rgb->battery_soc = value.intval;
			rgb->battery_mode = uke_rgb_battery_mode(value.intval, rgb->battery_mode);
		}
		/* Missing telemetry never clears an already reported low-battery warning. */
		if (!rgb->suspended)
			mod_delayed_work(system_freezable_wq, &rgb->pattern_work, 0);
		mod_delayed_work(system_freezable_wq, &rgb->battery_work, 60 * HZ);
	}
	mutex_unlock(&rgb->lock);
}
static int battery_event(struct notifier_block *nb, unsigned long event, void *data)
{
	struct uke_rgb *rgb = container_of(nb, struct uke_rgb, battery_notifier);
	struct power_supply *supply = data;

	if (event == PSY_EVENT_PROP_CHANGED && READ_ONCE(rgb->active) &&
	    !READ_ONCE(rgb->dead) && supply &&
	    !strcmp(supply->desc->name, "qcom-battmgr-bat"))
		mod_delayed_work(system_freezable_wq, &rgb->battery_work, 0);
	return NOTIFY_OK;
}
static int power_event(struct notifier_block *nb, unsigned long event, void *data)
{
	struct uke_rgb *rgb = container_of(nb, struct uke_rgb, pm_notifier);

	if (!READ_ONCE(rgb->active))
		return NOTIFY_OK;
	if (event == PM_SUSPEND_PREPARE || event == PM_HIBERNATION_PREPARE || event == PM_RESTORE_PREPARE) {
		mutex_lock(&rgb->lock);
		rgb->suspended = true;
		mutex_unlock(&rgb->lock);
		cancel_delayed_work_sync(&rgb->pattern_work);
		mutex_lock(&rgb->lock);
		if (!rgb->dead)
			output(rgb, (struct uke_rgb_frame){});
		mutex_unlock(&rgb->lock);
	} else if (event == PM_POST_SUSPEND || event == PM_POST_HIBERNATION || event == PM_POST_RESTORE) {
		mutex_lock(&rgb->lock);
		if (!rgb->dead) {
			rgb->suspended = false;
			rgb->epoch_ms = now_ms();
			mod_delayed_work(system_freezable_wq, &rgb->battery_work, 0);
		}
		mutex_unlock(&rgb->lock);
	}
	return NOTIFY_OK;
}
static int shutdown_event(struct notifier_block *nb, unsigned long event, void *data)
{
	struct uke_rgb *rgb = container_of(nb, struct uke_rgb, reboot_notifier);

	if (!READ_ONCE(rgb->active))
		return NOTIFY_OK;
	mutex_lock(&rgb->lock);
	rgb->dead = true;
	mutex_unlock(&rgb->lock);
	cancel_delayed_work_sync(&rgb->battery_work);
	cancel_delayed_work_sync(&rgb->pattern_work);
	mutex_lock(&rgb->lock);
	output(rgb, (struct uke_rgb_frame){});
	mutex_unlock(&rgb->lock);
	return NOTIFY_OK;
}
/* The future front-camera stream owner must call this in sleepable context. */
int uke_rgb_front_camera_active(bool active)
{
	struct uke_rgb *rgb;
	int ret = -ENODEV;

	mutex_lock(&controller_lock);
	rgb = controller;
	if (rgb) {
		mutex_lock(&rgb->lock);
		if (!rgb->dead && (!active || !rgb->suspended)) {
			rgb->camera = active;
			rgb->camera_seen = true;
			mod_delayed_work(system_freezable_wq, &rgb->pattern_work, 0);
			ret = 0;
		}
		mutex_unlock(&rgb->lock);
	}
	mutex_unlock(&controller_lock);
	return ret;
}
EXPORT_SYMBOL_GPL(uke_rgb_front_camera_active);

static int rgb_open(struct inode *inode, struct file *file)
{
	struct uke_rgb *rgb = container_of(file->private_data, struct uke_rgb, misc);
	int ret = -ENODEV;

	mutex_lock(&rgb->lock);
	if ((file->f_mode & FMODE_WRITE) && rgb->writer_open) {
		ret = -EBUSY;
		goto out;
	}
	if (!rgb->dead && rgb->active && kref_get_unless_zero(&rgb->ref)) {
		file->private_data = rgb;
		ret = nonseekable_open(inode, file);
		if (ret)
			kref_put(&rgb->ref, free_rgb);
		else if (file->f_mode & FMODE_WRITE)
			rgb->writer_open = true;
	}
 out:
	mutex_unlock(&rgb->lock);
	return ret;
}
static int rgb_release(struct inode *inode, struct file *file)
{
	struct uke_rgb *rgb = file->private_data;

	mutex_lock(&rgb->lock);
	if (file->f_mode & FMODE_WRITE) {
		rgb->writer_open = false;
		rgb->manual = false;
		rgb->test_until_ms = 0;
		if (!rgb->dead && !rgb->suspended)
			mod_delayed_work(system_freezable_wq, &rgb->pattern_work, 0);
	}
	mutex_unlock(&rgb->lock);
	kref_put(&rgb->ref, free_rgb);
	return 0;
}
static long rgb_ioctl(struct file *file, unsigned int command, unsigned long arg)
{
	struct uke_rgb *rgb = file->private_data;
	struct uke_rgb_color color = {};
	struct uke_rgb_status status = {};
	u64 now, deadline;
	int ret = 0;

	if (command != UKE_RGB_STATUS && command != UKE_RGB_SET &&
	    command != UKE_RGB_TEST_COLORS && command != UKE_RGB_AUTOMATIC)
		return -ENOTTY;
	if (!(file->f_mode & (command == UKE_RGB_STATUS ? FMODE_READ : FMODE_WRITE)))
		return -EBADF;
	if (command == UKE_RGB_SET) {
		if (copy_from_user(&color, (void __user *)arg, sizeof(color)))
			return -EFAULT;
		if (color.abi != UKE_RGB_ABI || color.rgb > 0xffffff ||
		    color.brightness_percent > 100 || color.reserved)
			return -EINVAL;
	}
	mutex_lock(&rgb->lock);
	if (rgb->dead) {
		ret = -ENODEV;
		goto out;
	}
	now = now_ms();
	switch (command) {
	case UKE_RGB_STATUS:
		status.abi = UKE_RGB_ABI;
		status.mode = selected(rgb, now);
		status.rgb = rgb->effective_rgb;
		status.brightness = rgb->effective_brightness;
		status.brightness_limit = UKE_RGB_LIMIT;
		status.requested_rgb = rgb->manual_rgb;
		status.requested_percent = rgb->manual_percent;
		status.battery_percent = rgb->battery_soc;
		status.battery_valid = rgb->battery_valid;
		status.test_remaining_ms = rgb->test_until_ms > now ? rgb->test_until_ms - now : 0;
		status.camera_active = rgb->camera;
		status.camera_source_seen = rgb->camera_seen;
		status.last_io_error = rgb->last_io_error;
		status.reserved = 0;
		break;
	case UKE_RGB_SET:
		rgb->manual_rgb = color.rgb;
		rgb->manual_percent = color.brightness_percent;
		rgb->manual = color.rgb && color.brightness_percent;
		break;
	case UKE_RGB_TEST_COLORS:
		if (rgb->suspended || rgb->camera || now < rgb->test_until_ms) {
			ret = -EBUSY;
			goto out;
		}
		if (check_add_overflow(now, (u64)UKE_RGB_TEST_MS, &deadline)) {
			ret = -EOVERFLOW;
			goto out;
		}
		rgb->test_until_ms = deadline;
		break;
	case UKE_RGB_AUTOMATIC:
		rgb->manual = false;
		rgb->test_until_ms = 0;
		break;
	}
	if (command != UKE_RGB_STATUS && !rgb->suspended)
		mod_delayed_work(system_freezable_wq, &rgb->pattern_work, 0);
 out:
	mutex_unlock(&rgb->lock);
	if (!ret && command == UKE_RGB_STATUS && copy_to_user((void __user *)arg, &status, sizeof(status)))
		ret = -EFAULT;
	return ret;
}
static const struct file_operations rgb_fops = {
	.owner = THIS_MODULE, .open = rgb_open, .release = rgb_release,
	.unlocked_ioctl = rgb_ioctl, .compat_ioctl = compat_ptr_ioctl,
};
static int rgb_probe(struct platform_device *pdev)
{
	struct led_classdev *led;
	struct led_classdev_mc *mc;
	struct uke_rgb *rgb;
	unsigned int mask = 0;
	bool sysfs_owned = false;
	int i, ret;

	if (!of_machine_is_compatible("xiaomi,uke") || !of_machine_is_compatible("qcom,sm7675"))
		return -ENODEV;
	led = devm_of_led_get(&pdev->dev, 0);
	if (IS_ERR(led))
		return dev_err_probe(&pdev->dev, PTR_ERR(led), "RGB supplier unavailable\n");
	if (strcmp(dev_name(led->dev), "uke:rgb:status") || !(led->flags & LED_MULTI_COLOR) ||
	    led->max_brightness != 511 || !led->dev->parent->driver ||
	    strcmp(led->dev->parent->driver->name, "qcom-spmi-lpg"))
		return -ENODEV;
	mc = lcdev_to_mccdev(led);
	if (mc->num_colors != 3)
		return -EINVAL;
	for (i = 0; i < mc->num_colors; i++) {
		unsigned int color = mc->subled_info[i].color_index;
		if (color < LED_COLOR_ID_RED || color > LED_COLOR_ID_BLUE || (mask & BIT(color)))
			return -EINVAL;
		mask |= BIT(color);
	}
	/* Managed supplier ordering unbinds this consumer before the LPG driver. */
	if (!device_link_add(&pdev->dev, led->dev->parent, DL_FLAG_AUTOREMOVE_CONSUMER))
		return -ENOMEM;
	mutex_lock(&controller_lock);
	if (controller) {
		ret = -EBUSY;
		goto unlock;
	}
	rgb = kzalloc(sizeof(*rgb), GFP_KERNEL);
	if (!rgb) {
		ret = -ENOMEM;
		goto unlock;
	}
	kref_init(&rgb->ref);
	mutex_init(&rgb->lock);
	rgb->led = led;
	rgb->mc = mc;
	rgb->battery_soc = -1;
	INIT_DELAYED_WORK(&rgb->pattern_work, pattern_work);
	INIT_DELAYED_WORK(&rgb->battery_work, battery_work);
	rgb->battery_notifier.notifier_call = battery_event;
	rgb->pm_notifier.notifier_call = power_event;
	rgb->reboot_notifier.notifier_call = shutdown_event;
	ret = power_supply_reg_notifier(&rgb->battery_notifier);
	if (ret)
		goto free;
	ret = register_pm_notifier(&rgb->pm_notifier);
	if (ret)
		goto unreg_battery;
	ret = register_reboot_notifier(&rgb->reboot_notifier);
	if (ret)
		goto unreg_pm;
	mutex_lock(&led->led_access);
	if (led_sysfs_is_disabled(led)) {
		mutex_unlock(&led->led_access);
		ret = -EBUSY;
		goto unreg_reboot;
	}
	led_sysfs_disable(led);
	sysfs_owned = true;
	led_trigger_remove(led);
	ret = output(rgb, (struct uke_rgb_frame){});
	mutex_unlock(&led->led_access);
	if (ret)
		goto unreg_reboot;
	rgb->active = true;
	rgb->misc = (struct miscdevice){ .minor = MISC_DYNAMIC_MINOR, .name = "uke-rgb",
		.fops = &rgb_fops, .parent = &pdev->dev, .mode = 0600 };
	ret = misc_register(&rgb->misc);
	if (ret)
		goto unreg_reboot;
	platform_set_drvdata(pdev, rgb);
	controller = rgb;
	mod_delayed_work(system_freezable_wq, &rgb->battery_work, 0);
	mutex_unlock(&controller_lock);
	return 0;
 unreg_reboot:
	mutex_lock(&rgb->lock);
	rgb->dead = true;
	mutex_unlock(&rgb->lock);
	unregister_reboot_notifier(&rgb->reboot_notifier);
 unreg_pm:
	unregister_pm_notifier(&rgb->pm_notifier);
 unreg_battery:
	power_supply_unreg_notifier(&rgb->battery_notifier);
	cancel_delayed_work_sync(&rgb->battery_work);
	cancel_delayed_work_sync(&rgb->pattern_work);
	if (sysfs_owned) {
		mutex_lock(&led->led_access);
		led_sysfs_enable(led);
		mutex_unlock(&led->led_access);
	}
 free:
	kref_put(&rgb->ref, free_rgb);
 unlock:
	mutex_unlock(&controller_lock);
	return ret;
}
static void rgb_remove(struct platform_device *pdev)
{
	struct uke_rgb *rgb = platform_get_drvdata(pdev);
	struct led_classdev *led = rgb->led;

	mutex_lock(&controller_lock);
	controller = NULL;
	mutex_lock(&rgb->lock);
	rgb->dead = true;
	mutex_unlock(&rgb->lock);
	mutex_unlock(&controller_lock);
	misc_deregister(&rgb->misc);
	power_supply_unreg_notifier(&rgb->battery_notifier);
	unregister_pm_notifier(&rgb->pm_notifier);
	unregister_reboot_notifier(&rgb->reboot_notifier);
	cancel_delayed_work_sync(&rgb->battery_work);
	cancel_delayed_work_sync(&rgb->pattern_work);
	mutex_lock(&led->led_access);
	led_set_brightness_sync(led, LED_OFF);
	led_sysfs_enable(led);
	mutex_unlock(&led->led_access);
	kref_put(&rgb->ref, free_rgb);
}
static const struct of_device_id rgb_match[] = {
	{ .compatible = "senemos,uke-rgb" }, {}
};
MODULE_DEVICE_TABLE(of, rgb_match);
static struct platform_driver rgb_driver = {
	.probe = rgb_probe, .remove = rgb_remove,
	.driver = { .name = "uke-rgb", .of_match_table = rgb_match },
};
module_platform_driver(rgb_driver);
MODULE_DESCRIPTION("Uke RGB notification policy and bounded control ABI");
MODULE_LICENSE("GPL");
