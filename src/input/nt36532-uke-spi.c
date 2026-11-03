// SPDX-License-Identifier: GPL-2.0-or-later
/* Uke native multitouch input.
 * Uke firmware, SPI, panel lifetime and gesture contracts remain board-specific.
 */
#include <crypto/sha2.h>
#include <linux/delay.h>
#include <linux/firmware.h>
#include <linux/gpio/consumer.h>
#include <linux/interrupt.h>
#include <linux/input.h>
#include <linux/input/mt.h>
#include <linux/input/touchscreen.h>
#include <linux/irq.h>
#include <linux/jiffies.h>
#include <linux/module.h>
#include <linux/notifier.h>
#include <linux/of.h>
#include <linux/power_supply.h>
#include <linux/pm_wakeup.h>
#include <linux/property.h>
#include <linux/slab.h>
#include <linux/spi/spi.h>
#include <linux/uke-o82-touch.h>
#include <linux/workqueue.h>
#include <drm/drm_panel.h>

#include "nt36532-uke-protocol.h"
#include "nt36532-uke-matrix.h"

#define NVT_UKE_WIRE_SIZE (NVT_UKE_FRAME_SIZE + 2)

struct nvt_uke_touch {
	struct spi_device *spi;
	struct input_dev *wake_input;
	struct touchscreen_properties prop;
	struct drm_panel_follower follower;
	struct notifier_block panel_notifier;
	struct notifier_block supply_notifier;
	const struct firmware *firmware;
	struct nvt_uke_io io;
	struct work_struct boot_work;
	struct work_struct charger_work;
	struct delayed_work poll_work;
	struct nvt_uke_matrix matrix;
	/* ctrl changes state; workers never acquire it or a panel lock. */
	struct mutex ctrl, io_lock, irq_lock;
	spinlock_t state_lock;
	u64 epoch, transfer_epoch, panel_state;
	bool panel_ready, suspended, removed, fault;
	bool irq_enabled, booted, idle_reset;
	bool gesture_io, gesture_armed, irq_wake;
	bool firmware_ready;
	bool charger_known, charger_online;
	unsigned int watchdog;
	u64 input_packets, input_errors;
	u64 io_errors, recovery_attempts;
	unsigned int recovery_budget;
	unsigned long last_irq, last_valid;
	u16 contacts_active;
	u16 candidate_counter;
	u8 candidate_count;
	bool candidate_valid;
	struct input_mt_pos motion_center;
	u8 motion_slot;
	bool motion_valid;
	u8 *tx, *rx, *frame;
};

static bool nvt_active(struct nvt_uke_touch *t)
{
	return t->panel_ready && !t->suspended &&
		!t->removed && !t->fault;
}

static void nvt_schedule_poll(struct nvt_uke_touch *t)
{
	unsigned long flags;

	/* Fence requeue against the state invalidation before quiesce/remove. */
	spin_lock_irqsave(&t->state_lock, flags);
	if (nvt_active(t) && t->booted && t->transfer_epoch == t->epoch)
		mod_delayed_work(system_long_wq, &t->poll_work, msecs_to_jiffies(20));
	spin_unlock_irqrestore(&t->state_lock, flags);
}

static void nvt_release_contacts(struct nvt_uke_touch *t)
{
	unsigned int i;

	if (!t->wake_input)
		return;
	for (i = 0; i < NVT_UKE_CONTACTS; i++) {
		input_mt_slot(t->wake_input, i);
		input_mt_report_slot_state(t->wake_input, MT_TOOL_FINGER, false);
	}
	input_mt_sync_frame(t->wake_input);
	input_sync(t->wake_input);
	t->contacts_active = 0;
	t->candidate_valid = false;
	t->motion_valid = false;
}

static int nvt_stable_axis(int value, int center, int margin, int maximum)
{
	if (!value || value == maximum)
		return value;
	if (value > center + margin)
		return value - margin;
	if (value < center - margin)
		return value + margin;
	return center;
}

static void nvt_order_new_slots(const struct input_mt_pos *positions, int *slots,
		unsigned int count, u16 previous, u16 starting)
{
	unsigned int i, j, selected, lowest, best, score, distance;
	u16 remaining = 0, visited = 0;
	int saved;

	if (count < 3)
		return;
	for (i = 0; i < count; i++) {
		if (previous & (1U << slots[i]))
			visited |= (u16)(1U << i);
		else if (starting & (1U << i))
			remaining |= (u16)(1U << i);
	}
	/* Slot-ordered consumers must see a coherent group without moving held IDs. */
	while (remaining) {
		selected = lowest = count;
		best = ~0U;
		for (i = 0; i < count; i++) {
			if (!(remaining & (1U << i)))
				continue;
			if (lowest == count || slots[i] < slots[lowest])
				lowest = i;
			score = visited ? ~0U : 0;
			for (j = 0; j < count; j++) {
				if (!((visited ? visited : remaining) & (1U << j)))
					continue;
				distance = (unsigned int)(abs(positions[i].x - positions[j].x) +
					abs(positions[i].y - positions[j].y));
				if (!visited)
					score += distance;
				else if (distance < score)
					score = distance;
			}
			if (selected == count || score < best) {
				selected = i;
				best = score;
			}
		}
		saved = slots[selected];
		slots[selected] = slots[lowest];
		slots[lowest] = saved;
		visited |= (u16)(1U << selected);
		remaining &= (u16)~(1U << selected);
	}
}

static void nvt_publish_contacts(struct nvt_uke_touch *t, int frame_error)
{
	struct nvt_uke_contacts contacts;
	struct nvt_uke_frame frame;
	struct input_mt_pos positions[NVT_UKE_CONTACTS];
	int slots[NVT_UKE_CONTACTS];
	unsigned int i, count = 0;
	bool confirmed;
	u16 starting = 0, previous = t->contacts_active;
	int ret = frame_error;

	if (!ret)
		ret = nvt_uke_decode(t->frame, NVT_UKE_FRAME_SIZE, &frame);
	if (!ret)
		ret = nvt_uke_matrix_process(&t->matrix, &frame,
					    t->prop.max_x, t->prop.max_y, &contacts);
	if (ret) {
		t->candidate_valid = false;
		t->input_errors++;
		if (time_after(jiffies, t->last_valid + msecs_to_jiffies(100)))
			nvt_release_contacts(t);
		dev_warn_ratelimited(&t->spi->dev, "Touch matrix packet rejected: %d\n", ret);
		return;
	}
	t->last_valid = jiffies;
	for (i = 0; i < NVT_UKE_CONTACTS; i++) {
		if (!(contacts.active & (1U << i)))
			continue;
		if (contacts.peak[i] >= NVT_UKE_PEAK_DOWN)
			starting |= (u16)(1U << count);
		touchscreen_set_mt_pos(&positions[count++], &t->prop, contacts.x[i], contacts.y[i]);
	}
	/* Confirm additions in two distinct sensor frames; held motion and lifts stay immediate. */
	confirmed = t->candidate_valid && t->candidate_counter != frame.counter &&
		t->candidate_count == count;
	if (!t->candidate_valid || t->candidate_counter != frame.counter) {
		t->candidate_counter = frame.counter;
		t->candidate_count = (u8)count;
		t->candidate_valid = true;
	}
	if (!confirmed)
		starting = 0;
	/* Preserve the nearest held contact when another finger joins the frame. */
	ret = input_mt_assign_slots(t->wake_input, slots, positions, count, 0);
	if (ret) {
		t->input_errors++;
		nvt_release_contacts(t);
		return;
	}
	for (i = 0; i < count; i++) {
		if (slots[i] < 0 || slots[i] >= NVT_UKE_CONTACTS) {
			/* A full old frame can leave no free slot for a distant new contact. */
			nvt_release_contacts(t);
			return;
		}
	}
	nvt_order_new_slots(positions, slots, count, previous, starting);
	/* Suppress single-finger contact-patch roll, without filtering fresh presses. */
	if (count == 1 && t->motion_valid && t->motion_slot == slots[0] &&
	    (previous & (1U << slots[0]))) {
		positions[0].x = nvt_stable_axis(positions[0].x, t->motion_center.x,
			t->prop.max_x / (2 * NVT_UKE_COLUMNS), t->prop.max_x);
		positions[0].y = nvt_stable_axis(positions[0].y, t->motion_center.y,
			t->prop.max_y / (2 * NVT_UKE_ROWS), t->prop.max_y);
	}
	t->contacts_active = 0;
	for (i = 0; i < count; i++) {
		/* A held finger may weaken without becoming a new touch on every frame. */
		if (!(starting & (1U << i)) && !(previous & (1U << slots[i])))
			continue;
		input_mt_slot(t->wake_input, (unsigned int)slots[i]);
		input_mt_report_slot_state(t->wake_input, MT_TOOL_FINGER, true);
		input_report_abs(t->wake_input, ABS_MT_POSITION_X, positions[i].x);
		input_report_abs(t->wake_input, ABS_MT_POSITION_Y, positions[i].y);
		t->contacts_active |= (u16)(1U << slots[i]);
	}
	t->motion_valid = count == 1 && t->contacts_active;
	if (t->motion_valid) {
		t->motion_center = positions[0];
		t->motion_slot = (u8)slots[0];
	}
	input_mt_sync_frame(t->wake_input);
	input_sync(t->wake_input);
	t->input_packets++;
}

static int nvt_ready(void *context)
{
	struct nvt_uke_touch *t = context;
	unsigned long flags;
	int ret;

	spin_lock_irqsave(&t->state_lock, flags);
	ret = (nvt_active(t) || (t->gesture_io && !t->suspended &&
		!t->removed && !t->fault)) && t->transfer_epoch == t->epoch ? 0 : -ESHUTDOWN;
	spin_unlock_irqrestore(&t->state_lock, flags);
	return ret;
}

/* io_lock owns the page, buffers and transfer_epoch for the entire operation. */
static int nvt_transfer(struct nvt_uke_touch *t, size_t size, bool receive, bool fast)
{
	struct spi_transfer xfer = {
		.tx_buf = t->tx, .rx_buf = receive ? t->rx : NULL,
		.len = size, .speed_hz = fast ? 19200000 : 1000000,
		.bits_per_word = 8,
	};
	struct spi_message message;
	int ret = nvt_ready(t);

	if (ret)
		return ret;
	spi_message_init_with_transfers(&message, &xfer, 1);
	ret = spi_sync(t->spi, &message);
	if (ret)
		return ret;
	if (message.actual_length != size)
		return -EIO;
	return nvt_ready(t);
}

static int nvt_spi_io(struct nvt_uke_touch *t, u32 address, void *data,
		      size_t size, bool read, bool fast)
{
	int ret;

	if (!data || !size || size > NVT_UKE_FRAME_SIZE ||
	    address > 0xffffff || size - 1 > 0xffffff - address)
		return -EINVAL;
	t->tx[0] = 0xff;
	t->tx[1] = address >> 15;
	t->tx[2] = address >> 7;
	ret = nvt_transfer(t, 3, false, false);
	if (ret)
		return ret;
	memset(t->tx, 0, size + 2);
	t->tx[0] = (address & 0x7f) | (read ? 0 : 0x80);
	if (!read)
		memcpy(t->tx + 1, data, size);
	ret = nvt_transfer(t, size + (read ? 2 : 1), read, fast);
	if (!ret && read)
		memcpy(data, t->rx + 2, size);
	return ret;
}

static int nvt_read(void *context, u32 address, void *data, size_t size, bool fast)
{
	return nvt_spi_io(context, address, data, size, true, fast);
}

static int nvt_write(void *context, u32 address, const void *data, size_t size, bool fast)
{
	return nvt_spi_io(context, address, (void *)data, size, false, fast);
}

static void nvt_delay(void *context, unsigned int milliseconds)
{
	msleep(milliseconds);
}

static int nvt_sha256(void *context, const u8 *data, size_t size, u8 digest[32])
{
	sha256(data, size, digest);
	return 0;
}

static void nvt_irq_set(struct nvt_uke_touch *t, bool enabled)
{
	unsigned long flags;
	bool active;

	mutex_lock(&t->irq_lock);
	spin_lock_irqsave(&t->state_lock, flags);
	active = (nvt_active(t) || (t->gesture_armed && !t->removed && !t->fault)) &&
		t->transfer_epoch == t->epoch;
	spin_unlock_irqrestore(&t->state_lock, flags);
	enabled &= active;
	if (enabled != t->irq_enabled) {
		if (enabled)
			enable_irq(t->spi->irq);
		else
			disable_irq(t->spi->irq);
		t->irq_enabled = enabled;
	}
	mutex_unlock(&t->irq_lock);
}

static void nvt_quiesce(struct nvt_uke_touch *t)
{
	int ret;
	unsigned long flags;

	/* State was invalidated first. Drain IRQ before its last work enqueue. */
	nvt_irq_set(t, false);
	cancel_delayed_work_sync(&t->poll_work);
	if (t->irq_wake) {
		ret = disable_irq_wake(t->spi->irq);
		if (ret)
			dev_err(&t->spi->dev, "THP wake IRQ disarm failed: %d\n", ret);
		else
			t->irq_wake = false;
	}
	cancel_work_sync(&t->boot_work);
	cancel_work_sync(&t->charger_work);
	mutex_lock(&t->io_lock);
	nvt_release_contacts(t);
	t->booted = false;
	spin_lock_irqsave(&t->state_lock, flags);
	t->gesture_armed = false;
	t->gesture_io = false;
	t->recovery_budget = 0;
	spin_unlock_irqrestore(&t->state_lock, flags);
	t->watchdog = 0;
	t->idle_reset = false;
	mutex_unlock(&t->io_lock);
}

static void nvt_fault(struct nvt_uke_touch *t)
{
	unsigned long flags;

	t->firmware_ready = false;
	spin_lock_irqsave(&t->state_lock, flags);
	t->fault = true;
	t->epoch++;
	spin_unlock_irqrestore(&t->state_lock, flags);
	nvt_release_contacts(t);
}

static void nvt_apply_charger(struct nvt_uke_touch *t)
{
	struct power_supply *supply;
	union power_supply_propval value;
	int ret;

	if (!t->booted || nvt_ready(t))
		return;
	supply = power_supply_get_by_name("qcom-battmgr-usb");
	if (!supply)
		return;
	ret = power_supply_get_property(supply, POWER_SUPPLY_PROP_ONLINE, &value);
	power_supply_put(supply);
	if (ret || (value.intval != 0 && value.intval != 1))
		return;
	if (t->charger_known && t->charger_online == value.intval)
		return;
	ret = nvt_uke_charger(&t->io, value.intval);
	if (!ret) {
		t->charger_online = value.intval;
		t->charger_known = true;
	} else if (ret != -ESHUTDOWN) {
		dev_warn_ratelimited(&t->spi->dev, "THP charger filter unavailable: %d\n", ret);
	}
}

static void nvt_charger_worker(struct work_struct *work)
{
	struct nvt_uke_touch *t = container_of(work, struct nvt_uke_touch, charger_work);

	mutex_lock(&t->io_lock);
	nvt_apply_charger(t);
	mutex_unlock(&t->io_lock);
}

static int nvt_supply_changed(struct notifier_block *nb, unsigned long event, void *data)
{
	struct nvt_uke_touch *t = container_of(nb, struct nvt_uke_touch, supply_notifier);
	struct power_supply *supply = data;

	if (event == PSY_EVENT_PROP_CHANGED &&
	    !strcmp(supply->desc->name, "qcom-battmgr-usb"))
		queue_work(system_long_wq, &t->charger_work);
	return NOTIFY_OK;
}

static void nvt_boot_worker(struct work_struct *work)
{
	struct nvt_uke_touch *t = container_of(work, struct nvt_uke_touch, boot_work);
	unsigned long flags;
	int ret;

	nvt_irq_set(t, false);
	mutex_lock(&t->io_lock);
	spin_lock_irqsave(&t->state_lock, flags);
	t->transfer_epoch = t->epoch;
	spin_unlock_irqrestore(&t->state_lock, flags);
	t->booted = false;
	t->firmware_ready = false;
	nvt_release_contacts(t);
	nvt_uke_matrix_reset(&t->matrix);
	ret = nvt_ready(t);
	if (!ret)
		ret = nvt_uke_boot(&t->io, t->firmware->data, t->firmware->size,
				   t->idle_reset);
	if (!ret)
		ret = nvt_uke_coordinate_mode(&t->io, false);
	t->idle_reset = false;
	t->watchdog = 0;
	if (!ret) {
		t->booted = true;
		t->firmware_ready = true;
		t->charger_known = false;
		t->last_irq = t->last_valid = jiffies;
		nvt_apply_charger(t);
	} else if (ret != -ESHUTDOWN) {
		nvt_fault(t);
		dev_err_ratelimited(&t->spi->dev, "THP firmware start failed: %d\n", ret);
	}
	mutex_unlock(&t->io_lock);
	if (!ret) {
		nvt_irq_set(t, true);
		nvt_schedule_poll(t);
	}
}

static void nvt_read_contacts(struct nvt_uke_touch *t)
{
	int ret, watchdog;
	unsigned long flags;
	bool recovery = false;

	if (!t->booted || nvt_ready(t))
		return;
	ret = nvt_uke_read_frame(&t->io, t->frame);
	if (ret) {
		if (ret != -ESHUTDOWN) {
			t->booted = false;
			t->io_errors++;
			nvt_fault(t);
			/* One verified cold reload per powered lifecycle, never a reset loop. */
			spin_lock_irqsave(&t->state_lock, flags);
			if (t->panel_ready && !t->suspended && !t->removed && t->recovery_budget) {
				t->recovery_budget = 0;
				t->fault = false;
				t->idle_reset = false;
				t->recovery_attempts++;
				recovery = true;
			}
			spin_unlock_irqrestore(&t->state_lock, flags);
			dev_warn_ratelimited(&t->spi->dev,
				"THP frame read failed: %d; bounded recovery=%u\n",
				ret, (unsigned int)recovery);
			/* The worker disables IRQ outside this threaded handler. */
			queue_work(system_long_wq, &t->boot_work);
		}
		return;
	}
	watchdog = nvt_uke_watchdog(t->frame, NVT_UKE_FRAME_SIZE, &t->watchdog);
	if (nvt_ready(t))
		return;
	if (watchdog > 0) {
		nvt_release_contacts(t);
		t->idle_reset = watchdog == 0xfd;
		t->booted = false;
		t->firmware_ready = false;
		queue_work(system_long_wq, &t->boot_work);
		return;
	}
	nvt_publish_contacts(t, 0);
}

static void nvt_poll_worker(struct work_struct *work)
{
	struct nvt_uke_touch *t = container_of(to_delayed_work(work), struct nvt_uke_touch, poll_work);

	mutex_lock(&t->io_lock);
	if (!t->gesture_armed && time_after_eq(jiffies, t->last_irq + msecs_to_jiffies(20)))
		nvt_read_contacts(t);
	mutex_unlock(&t->io_lock);
	nvt_schedule_poll(t);
}

static irqreturn_t nvt_irq_thread(int irq, void *context)
{
	struct nvt_uke_touch *t = context;

	mutex_lock(&t->io_lock);
	t->last_irq = jiffies;
	if (t->gesture_armed) {
		if (!nvt_ready(t) && device_may_wakeup(&t->spi->dev) &&
		    !nvt_uke_read_frame(&t->io, t->frame) &&
		    nvt_uke_double_tap(t->frame, NVT_UKE_GESTURE_SIZE) == 1) {
			pm_wakeup_event(&t->spi->dev, 500);
			input_report_key(t->wake_input, KEY_WAKEUP, 1);
			input_sync(t->wake_input);
			input_report_key(t->wake_input, KEY_WAKEUP, 0);
			input_sync(t->wake_input);
		}
	} else {
		nvt_read_contacts(t);
	}
	mutex_unlock(&t->io_lock);
	return IRQ_HANDLED;
}

static int nvt_panel_changed(struct notifier_block *nb, unsigned long event, void *data)
{
	struct nvt_uke_touch *t = container_of(nb, struct nvt_uke_touch, panel_notifier);
	u64 state = *(u64 *)data;
	unsigned long flags;
	bool active;
	int ret = NOTIFY_OK;

	mutex_lock(&t->ctrl);
	if (event == UKE_O82_TOUCH_RETAIN) {
		if (!device_may_wakeup(&t->spi->dev) || t->removed || t->fault || t->suspended)
			goto out;
		nvt_quiesce(t);
		mutex_lock(&t->io_lock);
		spin_lock_irqsave(&t->state_lock, flags);
		t->gesture_io = true;
		t->transfer_epoch = ++t->epoch;
		spin_unlock_irqrestore(&t->state_lock, flags);
		/* OEM keeps running firmware: REK calibration cannot finish after panel off. */
		ret = t->firmware_ready ? nvt_uke_gesture_enter(&t->io) : -EAGAIN;
		spin_lock_irqsave(&t->state_lock, flags);
		t->gesture_armed = !ret;
		t->gesture_io = !ret;
		spin_unlock_irqrestore(&t->state_lock, flags);
		mutex_unlock(&t->io_lock);
		if (ret) {
			dev_warn(&t->spi->dev, "THP gesture entry failed: %d; power retention refused\n", ret);
			ret = NOTIFY_BAD;
		} else {
			nvt_irq_set(t, true);
			ret = NOTIFY_STOP;
		}
		sysfs_notify(&t->spi->dev.kobj, NULL, "gesture_wake_armed");
		goto out;
	}
	if (event == UKE_O82_TOUCH_RELEASE) {
		nvt_quiesce(t);
		mutex_lock(&t->io_lock);
		t->firmware_ready = false;
		mutex_unlock(&t->io_lock);
		sysfs_notify(&t->spi->dev.kobj, NULL, "gesture_wake_armed");
		goto out;
	}
	if (state != t->panel_state) {
		spin_lock_irqsave(&t->state_lock, flags);
		t->panel_state = state;
		t->panel_ready = false;
		t->epoch++;
		spin_unlock_irqrestore(&t->state_lock, flags);
		nvt_quiesce(t);
		spin_lock_irqsave(&t->state_lock, flags);
		t->panel_ready = state & 1;
		if (t->panel_ready && !t->removed) {
			t->fault = false;
			t->recovery_budget = 1;
		}
		active = nvt_active(t);
		spin_unlock_irqrestore(&t->state_lock, flags);
		if (active)
			queue_work(system_long_wq, &t->boot_work);
	}
out:
	mutex_unlock(&t->ctrl);
	return ret;
}

static const struct drm_panel_follower_funcs nvt_follower_funcs = { };

static void nvt_wake_cleanup(void *data)
{
	device_init_wakeup(data, false);
}

static void nvt_firmware_cleanup(void *data)
{
	release_firmware(data);
}

static ssize_t gesture_wake_armed_show(struct device *dev,
		struct device_attribute *attr, char *buf)
{
	struct nvt_uke_touch *t = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%u\n", READ_ONCE(t->gesture_armed));
}
static DEVICE_ATTR_RO(gesture_wake_armed);
static ssize_t input_stats_show(struct device *dev,
		struct device_attribute *attr, char *buf)
{
	struct nvt_uke_touch *t = dev_get_drvdata(dev);
	ssize_t ret;

	mutex_lock(&t->io_lock);
	ret = sysfs_emit(buf, "packets=%llu errors=%llu active=0x%x calibrated=%u ready=%u "
		"io_errors=%llu recoveries=%llu fault=%u panel_ready=%u suspended=%u irq_enabled=%u\n",
			t->input_packets, t->input_errors, t->contacts_active,
			t->matrix.samples == NVT_UKE_CALIBRATION_FRAMES,
		t->booted && t->matrix.samples == NVT_UKE_CALIBRATION_FRAMES,
		t->io_errors, t->recovery_attempts, READ_ONCE(t->fault),
		READ_ONCE(t->panel_ready), READ_ONCE(t->suspended), READ_ONCE(t->irq_enabled));
	mutex_unlock(&t->io_lock);
	return ret;
}
static DEVICE_ATTR_RO(input_stats);
static struct attribute *nvt_attrs[] = {
	&dev_attr_gesture_wake_armed.attr, &dev_attr_input_stats.attr, NULL
};
ATTRIBUTE_GROUPS(nvt);

static int nvt_probe(struct spi_device *spi)
{
	struct device *dev = &spi->dev;
	struct gpio_desc *panel_id;
	struct nvt_uke_touch *t;
	u32 size_x, size_y;
	u32 mm_x, mm_y;
	const char *label, *supplier;
	enum nvt_uke_variant variant;
	int ret, panel_level;

	if (!of_machine_is_compatible("xiaomi,uke") || spi->max_speed_hz != 19200000 ||
	    spi->mode != SPI_MODE_0 || spi->irq <= 0 ||
	    irq_get_trigger_type(spi->irq) != IRQ_TYPE_EDGE_RISING)
		return -ENODEV;
	if (spi_max_transfer_size(spi) < NVT_UKE_WIRE_SIZE ||
	    spi_max_message_size(spi) < NVT_UKE_WIRE_SIZE)
		return dev_err_probe(dev, -EMSGSIZE, "Complete touch packet transfer required\n");
	if (device_property_read_string(dev, "novatek,firmware-variant", &supplier))
		return dev_err_probe(dev, -EINVAL, "Touch supplier identity required\n");
	ret = nvt_uke_variant_from_name(supplier);
	if (ret < 0)
		return dev_err_probe(dev, ret, "Unsupported touch supplier\n");
	variant = (enum nvt_uke_variant)ret;
	panel_id = devm_gpiod_get(dev, "panel-id", GPIOD_ASIS);
	if (IS_ERR(panel_id))
		return dev_err_probe(dev, PTR_ERR(panel_id), "Panel ID unavailable\n");
	ret = gpiod_get_direction(panel_id);
	if (ret < 0)
		return dev_err_probe(dev, ret, "Panel ID direction unavailable\n");
	panel_level = gpiod_get_value_cansleep(panel_id);
	if (panel_level < 0)
		return dev_err_probe(dev, panel_level, "Panel ID value unavailable\n");
	ret = nvt_uke_panel_id(variant, ret, panel_level);
	if (ret)
		return dev_err_probe(dev, ret, "Invalid panel-ID input for touch supplier\n");
	if (device_property_read_u32(dev, "touchscreen-size-x", &size_x) ||
	    device_property_read_u32(dev, "touchscreen-size-y", &size_y) ||
	    size_x != 32000 || size_y != 21360 ||
	    device_property_read_string(dev, "label", &label) || !*label || strlen(label) > 79 ||
	    device_property_read_u32(dev, "touchscreen-x-mm", &mm_x) ||
	    device_property_read_u32(dev, "touchscreen-y-mm", &mm_y) ||
	    mm_x < 1 || mm_x > 1000 || mm_y < 1 || mm_y > 1000)
		return dev_err_probe(dev, -EINVAL, "Bounded DT touch geometry required\n");
	t = devm_kzalloc(dev, sizeof(*t), GFP_KERNEL);
	if (!t)
		return -ENOMEM;
	t->spi = spi;
	mutex_init(&t->ctrl);
	mutex_init(&t->io_lock);
	mutex_init(&t->irq_lock);
	spin_lock_init(&t->state_lock);
	INIT_WORK(&t->boot_work, nvt_boot_worker);
	INIT_WORK(&t->charger_work, nvt_charger_worker);
	INIT_DELAYED_WORK(&t->poll_work, nvt_poll_worker);
	if (device_property_read_u32_array(dev, "novatek,column-map", t->matrix.columns, NVT_UKE_COLUMNS) ||
	    device_property_read_u32_array(dev, "novatek,row-map", t->matrix.rows, NVT_UKE_ROWS))
		return dev_err_probe(dev, -EINVAL, "Supplier electrode mapping required\n");
	t->io = (struct nvt_uke_io) {
		.context = t, .read = nvt_read, .write = nvt_write,
		.check_ready = nvt_ready, .delay_ms = nvt_delay, .sha256 = nvt_sha256,
		.variant = variant,
	};
	t->tx = devm_kmalloc(dev, NVT_UKE_WIRE_SIZE, GFP_KERNEL);
	t->rx = devm_kmalloc(dev, NVT_UKE_WIRE_SIZE, GFP_KERNEL);
	t->frame = devm_kmalloc(dev, NVT_UKE_FRAME_SIZE, GFP_KERNEL);
	if (!t->tx || !t->rx || !t->frame)
		return -ENOMEM;
	ret = request_firmware(&t->firmware, nvt_uke_firmware(variant), dev);
	if (ret)
		return ret;
	ret = devm_add_action_or_reset(dev, nvt_firmware_cleanup, (void *)t->firmware);
	if (ret)
		return ret;
	ret = nvt_uke_validate_image(&t->io, t->firmware->data, t->firmware->size);
	if (ret)
		return ret;
	spi->bits_per_word = 8;
	ret = spi_setup(spi);
	if (ret)
		return ret;
	t->wake_input = devm_input_allocate_device(dev);
	if (!t->wake_input)
		return -ENOMEM;
	t->wake_input->name = label;
	t->wake_input->phys = devm_kasprintf(dev, GFP_KERNEL, "%s/input0", dev_name(dev));
	if (!t->wake_input->phys)
		return -ENOMEM;
	t->wake_input->id.bustype = BUS_SPI;
	input_set_capability(t->wake_input, EV_KEY, KEY_WAKEUP);
	input_set_abs_params(t->wake_input, ABS_MT_POSITION_X, 0, size_x - 1, 0, 0);
	input_set_abs_params(t->wake_input, ABS_MT_POSITION_Y, 0, size_y - 1, 0, 0);
	input_abs_set_res(t->wake_input, ABS_MT_POSITION_X, size_x / mm_x);
	input_abs_set_res(t->wake_input, ABS_MT_POSITION_Y, size_y / mm_y);
	touchscreen_parse_properties(t->wake_input, true, &t->prop);
	ret = input_mt_init_slots(t->wake_input, NVT_UKE_CONTACTS,
				 INPUT_MT_DIRECT | INPUT_MT_DROP_UNUSED | INPUT_MT_TRACK);
	if (ret)
		return ret;
	ret = input_register_device(t->wake_input);
	if (ret)
		return ret;
	ret = device_init_wakeup(dev, device_property_present(dev, "wakeup-source"));
	if (ret)
		return ret;
	ret = devm_add_action_or_reset(dev, nvt_wake_cleanup, dev);
	if (ret)
		return ret;
	spi_set_drvdata(spi, t);
	ret = devm_request_threaded_irq(dev, spi->irq, NULL, nvt_irq_thread,
			IRQF_ONESHOT | IRQF_NO_AUTOEN, dev_name(dev), t);
	if (ret)
		goto error;
	t->follower.funcs = &nvt_follower_funcs;
	ret = drm_panel_add_follower(dev, &t->follower);
	if (ret)
		goto free_irq;
	if (!device_link_add(dev, t->follower.panel->dev, DL_FLAG_AUTOREMOVE_CONSUMER)) {
		ret = -ENODEV;
		goto follower;
	}
	t->supply_notifier.notifier_call = nvt_supply_changed;
	ret = power_supply_reg_notifier(&t->supply_notifier);
	if (ret)
		goto follower;
	t->panel_notifier.notifier_call = nvt_panel_changed;
	ret = uke_o82_touch_register(t->follower.panel, &t->panel_notifier);
	if (!ret)
		return 0;
	power_supply_unreg_notifier(&t->supply_notifier);
	nvt_quiesce(t);
follower:
	drm_panel_remove_follower(&t->follower);
free_irq:
	devm_free_irq(dev, spi->irq, t);
error:
	spi_set_drvdata(spi, NULL);
	return dev_err_probe(dev, ret, "Native touch registration failed\n");
}

static void nvt_remove(struct spi_device *spi)
{
	struct nvt_uke_touch *t = spi_get_drvdata(spi);
	unsigned long flags;

	mutex_lock(&t->ctrl);
	spin_lock_irqsave(&t->state_lock, flags);
	t->removed = true;
	t->epoch++;
	spin_unlock_irqrestore(&t->state_lock, flags);
	mutex_unlock(&t->ctrl);
	uke_o82_touch_unregister(t->follower.panel, &t->panel_notifier);
	power_supply_unreg_notifier(&t->supply_notifier);
	nvt_quiesce(t);
	devm_free_irq(&spi->dev, spi->irq, t);
	drm_panel_remove_follower(&t->follower);
	spi_set_drvdata(spi, NULL);
}

static int nvt_suspend(struct device *dev)
{
	struct nvt_uke_touch *t = dev_get_drvdata(dev);
	unsigned long flags;
	int ret = 0;

	mutex_lock(&t->ctrl);
	if (t->irq_wake) {
		ret = -EBUSY;
		goto out;
	}
	if (t->gesture_armed && device_may_wakeup(dev) && !t->removed) {
		ret = enable_irq_wake(t->spi->irq);
		if (ret)
			goto out;
		t->irq_wake = true;
	}
	spin_lock_irqsave(&t->state_lock, flags);
	t->suspended = true;
	if (!t->irq_wake)
		t->epoch++;
	spin_unlock_irqrestore(&t->state_lock, flags);
	if (!t->irq_wake) {
		nvt_quiesce(t);
		mutex_lock(&t->io_lock);
		t->firmware_ready = false;
		mutex_unlock(&t->io_lock);
	}
out:
	mutex_unlock(&t->ctrl);
	return ret;
}

static int nvt_resume(struct device *dev)
{
	struct nvt_uke_touch *t = dev_get_drvdata(dev);
	unsigned long flags;
	bool active;
	int ret;

	mutex_lock(&t->ctrl);
	if (t->irq_wake) {
		ret = disable_irq_wake(t->spi->irq);
		if (ret) {
			mutex_unlock(&t->ctrl);
			return ret;
		}
		t->irq_wake = false;
	}
	spin_lock_irqsave(&t->state_lock, flags);
	t->suspended = false;
	if (!t->gesture_armed) {
		t->epoch++;
		if (t->panel_ready && !t->removed) {
			t->fault = false;
			t->recovery_budget = 1;
		}
	}
	active = nvt_active(t);
	spin_unlock_irqrestore(&t->state_lock, flags);
	if (active)
		queue_work(system_long_wq, &t->boot_work);
	mutex_unlock(&t->ctrl);
	return 0;
}

static DEFINE_SIMPLE_DEV_PM_OPS(nvt_pm_ops, nvt_suspend, nvt_resume);

static void nvt_shutdown(struct spi_device *spi)
{
	struct nvt_uke_touch *t = spi_get_drvdata(spi);
	unsigned long flags;

	mutex_lock(&t->ctrl);
	spin_lock_irqsave(&t->state_lock, flags);
	t->removed = true;
	t->suspended = true;
	t->epoch++;
	spin_unlock_irqrestore(&t->state_lock, flags);
	nvt_quiesce(t);
	mutex_unlock(&t->ctrl);
}

static const struct of_device_id nvt_matches[] = {
	{ .compatible = "novatek,nt36532-uke-touch" }, { }
};
MODULE_DEVICE_TABLE(of, nvt_matches);

static const struct spi_device_id nvt_spi_ids[] = {
	{ "nt36532-uke-touch", 0 }, { }
};
MODULE_DEVICE_TABLE(spi, nvt_spi_ids);

static struct spi_driver nvt_driver = {
	.driver = {
		.name = "nt36532-uke-touch",
		.of_match_table = nvt_matches,
		.pm = pm_sleep_ptr(&nvt_pm_ops),
		.dev_groups = nvt_groups,
	},
	.probe = nvt_probe,
	.remove = nvt_remove,
	.shutdown = nvt_shutdown,
	.id_table = nvt_spi_ids,
};
module_spi_driver(nvt_driver);
MODULE_FIRMWARE("qcom/uke/touch/csot/normal.bin");
MODULE_FIRMWARE("qcom/uke/touch/tm/normal.bin");
MODULE_DESCRIPTION("Uke NT36532 signed raw THP packet transport");
MODULE_LICENSE("GPL");
