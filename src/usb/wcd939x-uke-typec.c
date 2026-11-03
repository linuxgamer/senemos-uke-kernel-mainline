// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (c) 2022 Qualcomm Innovation Center, Inc. All rights reserved.
 * Copyright (C) 2023 Linaro Ltd.
 *
 * Uke WCD939x USB2 and DisplayPort AUX routing.
 * Register sequences: MiCode uke-v-oss 5712080a, wcd939x-i2c.c.
 * Type-C framework pattern: wcd939x-usbss.c, Qualcomm/Linaro, GPL-2.0-only.
 * CC, VBUS and PD remain owned by firmware. No raw register userspace API.
 */
#include <linux/bitfield.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of_platform.h>
#include <linux/pinctrl/consumer.h>
#include <linux/platform_device.h>
#include <linux/reset-controller.h>
#include <linux/regmap.h>
#include <linux/regulator/consumer.h>
#include <linux/usb/typec_dp.h>
#include <linux/usb/typec_mux.h>

#define DP_DN_MISC1 0x20
#define MG1_EN 0x24
#define MG2_EN 0x28
#define FSM_OVERRIDE 0x63
#define AUXP_THRESH 0x80
#define AUXP_CTL 0x81
#define AUXM_THRESH 0x82
#define CPLDO_CTL2 0xa1
#define SWITCH_ENABLE 0x403
#define SWITCH_SELECT 0x404
#define SWITCH_STATUS1 0x407
#define FUNCTION_ENABLE 0x413
#define EQUALIZER 0x415
#define USB_CONTROL 0x419
#define CHIP_ID1 0x439
#define DEVICE_EN BIT(7)
#define AUX_EN GENMASK(6, 5)
#define USB_EN (BIT(4) | BIT(3))
#define AUX_SEL GENMASK(7, 6)
#define USB_SEL GENMASK(5, 2)
#define EQ_EN BIT(7)

struct uke_usbss {
	struct regmap *regmap;
	struct regulator *supply;
	struct gpio_desc *reset;
	struct mutex lock;
	struct typec_switch_dev *sw;
	struct typec_mux_dev *mux;
	enum typec_orientation orientation;
	unsigned long mode;
	unsigned int svid, revision;
	int last_error;
	bool applied, removing;
};

struct uke_codec_reset {
	struct reset_controller_dev controller;
	struct uke_usbss *usbss;
	struct pinctrl *pinctrl;
	struct pinctrl_state *active, *sleep;
};

/* OS3 WCD reset brackets LPASS GPIO12 with the USBSS threshold override. */
static int uke_codec_reset_cycle(struct reset_controller_dev *controller,
				unsigned long id)
{
	struct uke_codec_reset *r = container_of(controller, struct uke_codec_reset, controller);
	struct uke_usbss *u = r->usbss;
	unsigned int value;
	bool protection_failed = false;
	int ret, restore;

	if (id)
		return -EINVAL;
	mutex_lock(&u->lock);
	if (u->removing) {
		ret = -ESHUTDOWN;
		goto unlock;
	}
	ret = regmap_read(u->regmap, FSM_OVERRIDE, &value);
	if (ret)
		goto unlock;
	if ((value & 0x7f) != 0x7f) {
		ret = -EPROTO;
		goto unlock;
	}
	ret = regmap_read(u->regmap, 0x1e, &value);
	if (ret)
		goto unlock;
	if ((value & 0x0e) != 0x0c) {
		ret = -EPROTO;
		goto unlock;
	}
	ret = regmap_read(u->regmap, 0x21, &value);
	if (ret)
		goto unlock;
	if ((value & 0x0e) != 0x0c) {
		ret = -EPROTO;
		goto unlock;
	}
	ret = regmap_clear_bits(u->regmap, FSM_OVERRIDE, BIT(3));
	if (ret)
		goto restore;
	ret = regmap_update_bits(u->regmap, 0x1e, 0x0e, 0x08);
	if (ret)
		goto restore;
	ret = regmap_update_bits(u->regmap, 0x21, 0x0e, 0x08);
	if (ret)
		goto restore;
	ret = pinctrl_select_state(r->pinctrl, r->sleep);
	if (ret)
		goto restore;
	usleep_range(80, 85);
	ret = pinctrl_select_state(r->pinctrl, r->active);
	if (ret)
		goto restore;
	usleep_range(80, 85);
restore:
	/* Attempt every protection restore; retain the first failure. */
	restore = regmap_update_bits(u->regmap, 0x1e, 0x0e, 0x0c);
	protection_failed |= !!restore;
	if (!ret)
		ret = restore;
	restore = regmap_update_bits(u->regmap, 0x21, 0x0e, 0x0c);
	protection_failed |= !!restore;
	if (!ret)
		ret = restore;
	restore = regmap_set_bits(u->regmap, FSM_OVERRIDE, BIT(3));
	protection_failed |= !!restore;
	if (!ret)
		ret = restore;
	if (ret)
		pinctrl_select_state(r->pinctrl, r->sleep);
	if (protection_failed) {
		u->applied = false;
		u->last_error = ret;
	}
unlock:
	mutex_unlock(&u->lock);
	return ret;
}

static const struct reset_control_ops uke_codec_reset_ops = {
	.reset = uke_codec_reset_cycle,
};

static int uke_codec_reset_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct uke_codec_reset *r;

	if (!dev->parent || !dev->parent->of_node ||
	    !of_device_is_compatible(dev->parent->of_node, "xiaomi,uke-wcd939x-typec"))
		return -ENODEV;
	r = devm_kzalloc(dev, sizeof(*r), GFP_KERNEL);
	if (!r)
		return -ENOMEM;
	r->usbss = dev_get_drvdata(dev->parent);
	if (!r->usbss)
		return -EPROBE_DEFER;
	r->pinctrl = devm_pinctrl_get(dev);
	if (IS_ERR(r->pinctrl))
		return dev_err_probe(dev, PTR_ERR(r->pinctrl), "codec reset pins unavailable\n");
	r->active = pinctrl_lookup_state(r->pinctrl, "active");
	if (IS_ERR(r->active))
		return PTR_ERR(r->active);
	r->sleep = pinctrl_lookup_state(r->pinctrl, "sleep");
	if (IS_ERR(r->sleep))
		return PTR_ERR(r->sleep);
	r->controller = (struct reset_controller_dev) {
		.dev = dev,
		.owner = THIS_MODULE,
		.ops = &uke_codec_reset_ops,
		.of_node = dev->of_node,
		.nr_resets = 1,
		.of_reset_n_cells = 1,
	};
	return devm_reset_controller_register(dev, &r->controller);
}

static const struct of_device_id uke_codec_reset_match[] = {
	{ .compatible = "xiaomi,uke-wcd939x-codec-reset" }, { }
};
MODULE_DEVICE_TABLE(of, uke_codec_reset_match);
static struct platform_driver uke_codec_reset_driver = {
	.probe = uke_codec_reset_probe,
	.driver = { .name = "uke-wcd939x-codec-reset", .of_match_table = uke_codec_reset_match },
};

static const struct regmap_range_cfg uke_usbss_ranges[] = {
	{ .range_min = 0, .range_max = 0x4c1, .selector_reg = 0,
	  .selector_mask = 0xff, .window_start = 0, .window_len = 0x100 },
};
static const struct regmap_config uke_usbss_regmap = {
	.reg_bits = 8, .val_bits = 8, .max_register = 0x4c1,
	.ranges = uke_usbss_ranges, .num_ranges = ARRAY_SIZE(uke_usbss_ranges),
};

/* Called with lock held. USB2 stays routed with both two- and four-lane DP. */
static int uke_usbss_apply(struct uke_usbss *u, enum typec_orientation orientation,
			   unsigned long mode, unsigned int svid)
{
	bool dp = false, connected = orientation != TYPEC_ORIENTATION_NONE;
	unsigned int status, selection = orientation == TYPEC_ORIENTATION_REVERSE ? 0x80 : 0x40;
	int ret;

	if (u->removing)
		return -ESHUTDOWN;
	if (orientation != TYPEC_ORIENTATION_NONE &&
	    orientation != TYPEC_ORIENTATION_NORMAL &&
	    orientation != TYPEC_ORIENTATION_REVERSE) {
		ret = -EINVAL;
		goto failed;
	}
	if (mode < TYPEC_STATE_MODAL) {
		/* SAFE/USB must also work while an altmode object still exists. */
	} else if (svid == USB_TYPEC_DP_SID) {
		switch (mode) {
		case TYPEC_DP_STATE_C: case TYPEC_DP_STATE_D:
		case TYPEC_DP_STATE_E: case TYPEC_DP_STATE_F:
			dp = connected;
			break;
		default: ret = -EOPNOTSUPP; goto failed;
		}
	} else if (svid || (mode != TYPEC_MODE_USB2 && mode != TYPEC_MODE_USB3)) {
		ret = -EOPNOTSUPP;
		goto failed;
	}

	if (u->applied && u->orientation == orientation &&
	    u->mode == mode && u->svid == svid)
		return 0;
	u->applied = false;
	ret = regmap_clear_bits(u->regmap, SWITCH_ENABLE, AUX_EN);
	if (ret) goto failed;
	ret = regmap_update_bits(u->regmap, SWITCH_SELECT, AUX_SEL | USB_SEL,
				0x14 | (dp ? selection : 0));
	if (ret) goto failed;
	ret = regmap_set_bits(u->regmap, SWITCH_ENABLE, DEVICE_EN | USB_EN);
	if (ret) goto failed;
	/* Exact Uke host/device bandwidth is 8; SAFE/disconnect leaves EQ off. */
	ret = regmap_update_bits(u->regmap, EQUALIZER, GENMASK(6, 3) | EQ_EN,
				FIELD_PREP(GENMASK(6, 3), 8) |
				(connected && mode != TYPEC_STATE_SAFE ? EQ_EN : 0));
	if (ret) goto failed;
	if (dp) {
		usleep_range(35, 100);
		ret = regmap_set_bits(u->regmap, SWITCH_ENABLE, AUX_EN);
		if (ret) goto failed;
		usleep_range(15, 100);
		ret = regmap_read(u->regmap, SWITCH_STATUS1, &status);
		if (ret) goto failed;
		/* OEM STATUS1 reports AUX routing; STATUS0 reports USB DP/DM.
		 * Ignore unrelated microphone/ground status as the OEM does.
		 */
		if ((status & 0xcc) != (selection == 0x40 ? 0x48 : 0x84)) {
			ret = -EIO;
			goto failed;
		}
	}
	u->orientation = orientation; u->mode = mode; u->svid = svid;
	u->last_error = 0; u->applied = true;
	return 0;
failed:
	u->applied = false;
	/* Preserve the original errno even if this best-effort isolation also fails. */
	regmap_clear_bits(u->regmap, SWITCH_ENABLE, AUX_EN | USB_EN);
	regmap_clear_bits(u->regmap, EQUALIZER, EQ_EN);
	u->last_error = ret;
	return ret;
}

static int uke_usbss_orientation(struct typec_switch_dev *sw, enum typec_orientation orientation)
{
	struct uke_usbss *u = typec_switch_get_drvdata(sw);
	int ret;
	mutex_lock(&u->lock);
	ret = uke_usbss_apply(u, orientation, u->mode, u->svid);
	mutex_unlock(&u->lock);
	return ret;
}

static int uke_usbss_mode(struct typec_mux_dev *mux, struct typec_mux_state *state)
{
	struct uke_usbss *u = typec_mux_get_drvdata(mux);
	unsigned int svid = state->alt ? state->alt->svid : 0;
	int ret;
	mutex_lock(&u->lock);
	ret = uke_usbss_apply(u, u->orientation, state->mode, svid);
	mutex_unlock(&u->lock);
	return ret;
}

static ssize_t route_state_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct uke_usbss *u = dev_get_drvdata(dev);
	ssize_t bytes;
	mutex_lock(&u->lock);
	bytes = sysfs_emit(buf, "version=1 revision=0x%02x orientation=%u mode=%lu svid=0x%04x applied=%u errno=%d\n",
			u->revision, u->orientation, u->mode, u->svid, u->applied, u->last_error);
	mutex_unlock(&u->lock);
	return bytes;
}
static DEVICE_ATTR_RO(route_state);
static struct attribute *uke_usbss_attrs[] = { &dev_attr_route_state.attr, NULL };
ATTRIBUTE_GROUPS(uke_usbss);

static int uke_usbss_probe(struct i2c_client *client)
{
	struct device *dev = &client->dev;
	struct typec_switch_desc sw = { .fwnode = dev_fwnode(dev), .set = uke_usbss_orientation };
	struct typec_mux_desc mux = { .fwnode = dev_fwnode(dev), .set = uke_usbss_mode };
	struct uke_usbss *u;
	int ret;

	u = devm_kzalloc(dev, sizeof(*u), GFP_KERNEL);
	if (!u) return -ENOMEM;
	mutex_init(&u->lock);
	u->regmap = devm_regmap_init_i2c(client, &uke_usbss_regmap);
	if (IS_ERR(u->regmap)) return PTR_ERR(u->regmap);
	u->supply = devm_regulator_get(dev, "vdd-usb-cp");
	if (IS_ERR(u->supply)) return PTR_ERR(u->supply);
	u->reset = devm_gpiod_get(dev, "reset", GPIOD_OUT_HIGH);
	if (IS_ERR(u->reset)) return PTR_ERR(u->reset);
	ret = regulator_enable(u->supply);
	if (ret) return ret;
	msleep(20); gpiod_set_value_cansleep(u->reset, 0); msleep(20);
	ret = regmap_read(u->regmap, CHIP_ID1, &u->revision);
	if (ret) goto power_off;
	/* OEM enum: 0 = 1.x, 1 = Harmonium 2.0. This profile is exact 2.0. */
	if (u->revision != 1) { ret = -ENODEV; goto power_off; }
	ret = regmap_update_bits(u->regmap, USB_CONTROL, 0x17, 0x05);
	if (ret) goto power_off;
	ret = regmap_write(u->regmap, CPLDO_CTL2, 0xff);
	if (ret) goto power_off;
	ret = regmap_clear_bits(u->regmap, USB_CONTROL, BIT(3));
	if (ret) goto power_off;
	ret = regmap_set_bits(u->regmap, USB_CONTROL, BIT(3));
	if (ret) goto power_off;
	ret = regmap_update_bits(u->regmap, FUNCTION_ENABLE, 3, 1);
	if (ret) goto power_off;
	ret = regmap_set_bits(u->regmap, DP_DN_MISC1, 0x09);
	if (ret) goto power_off;
	ret = regmap_update_bits(u->regmap, 0x27, 0x24, 0x24);
	if (ret) goto power_off;
	ret = regmap_update_bits(u->regmap, 0x30, 0x24, 0x24);
	if (ret) goto power_off;
	/* Exact O82 final fuse overrides; EQ remains gated by OVP (bit 5). */
	ret = regmap_update_bits(u->regmap, FSM_OVERRIDE, 0x7f, 0x7f);
	if (ret) goto power_off;
	ret = regmap_update_bits(u->regmap, 0x1e, 0x0e, 0x0c);
	if (ret) goto power_off;
	ret = regmap_update_bits(u->regmap, 0x21, 0x0e, 0x0c);
	if (ret) goto power_off;
	ret = regmap_update_bits(u->regmap, AUXP_CTL, 7, 1);
	if (ret) goto power_off;
	ret = regmap_update_bits(u->regmap, AUXP_THRESH, 0xe0, 0xe0);
	if (ret) goto power_off;
	ret = regmap_update_bits(u->regmap, AUXM_THRESH, 0xe0, 0xe0);
	if (ret) goto power_off;
	ret = regmap_update_bits(u->regmap, MG1_EN, 0x0e, 0x0c);
	if (ret) goto power_off;
	ret = regmap_update_bits(u->regmap, MG2_EN, 0x0e, 0x0c);
	if (ret) goto power_off;
	ret = uke_usbss_apply(u, TYPEC_ORIENTATION_NONE, TYPEC_STATE_SAFE, 0);
	if (ret) goto power_off;
	i2c_set_clientdata(client, u);
	sw.drvdata = u; mux.drvdata = u;
	u->sw = typec_switch_register(dev, &sw);
	if (IS_ERR(u->sw)) { ret = PTR_ERR(u->sw); goto power_off; }
	u->mux = typec_mux_register(dev, &mux);
	if (IS_ERR(u->mux)) { ret = PTR_ERR(u->mux); goto unregister_switch; }
	ret = devm_of_platform_populate(dev);
	if (ret)
		goto depopulate_children;
	return 0;
depopulate_children:
	mutex_lock(&u->lock);
	u->removing = true; u->applied = false;
	mutex_unlock(&u->lock);
	/* A failed population has no devres action to undo partial children. */
	of_platform_depopulate(dev);
	typec_mux_unregister(u->mux);
unregister_switch:
	mutex_lock(&u->lock);
	u->removing = true; u->applied = false;
	mutex_unlock(&u->lock);
	typec_switch_unregister(u->sw);
power_off:
	gpiod_set_value_cansleep(u->reset, 1);
	regulator_disable(u->supply);
	return dev_err_probe(dev, ret, "Uke WCD Type-C routing initialization failed\n");
}

static void uke_usbss_remove(struct i2c_client *client)
{
	struct uke_usbss *u = i2c_get_clientdata(client);
	mutex_lock(&u->lock);
	u->removing = true; u->applied = false;
	mutex_unlock(&u->lock);
	devm_of_platform_depopulate(&client->dev);
	typec_mux_unregister(u->mux); typec_switch_unregister(u->sw);
	regmap_clear_bits(u->regmap, SWITCH_ENABLE, AUX_EN | USB_EN);
	gpiod_set_value_cansleep(u->reset, 1);
	regulator_disable(u->supply);
}
static const struct of_device_id uke_usbss_match[] = {
	{ .compatible = "xiaomi,uke-wcd939x-typec" }, { }
};
MODULE_DEVICE_TABLE(of, uke_usbss_match);
static struct i2c_driver uke_usbss_driver = {
	.probe = uke_usbss_probe, .remove = uke_usbss_remove,
	.driver = { .name = "wcd939x-uke-typec", .of_match_table = uke_usbss_match,
		    .dev_groups = uke_usbss_groups },
};
static int __init uke_usbss_init(void)
{
	int ret = platform_driver_register(&uke_codec_reset_driver);
	if (ret)
		return ret;
	ret = i2c_add_driver(&uke_usbss_driver);
	if (ret)
		platform_driver_unregister(&uke_codec_reset_driver);
	return ret;
}
module_init(uke_usbss_init);

static void __exit uke_usbss_exit(void)
{
	i2c_del_driver(&uke_usbss_driver);
	platform_driver_unregister(&uke_codec_reset_driver);
}
module_exit(uke_usbss_exit);
MODULE_DESCRIPTION("Uke WCD939x USB2 and DisplayPort AUX Type-C routing");
MODULE_LICENSE("GPL");
