// SPDX-License-Identifier: GPL-2.0-only
/* Import the actual sensor function; only firmware-description APIs are modeled. */
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define V4L2_MBUS_CSI2_DPHY 4
typedef long long s64;
struct device { int unused; };
struct fwnode_handle { int unused; };
struct v4l2_fwnode_endpoint {
	int bus_type;
	struct { struct { unsigned int num_data_lanes; } mipi_csi2; } bus;
	unsigned int nr_of_link_frequencies;
	s64 *link_frequencies;
};
struct ov08d10_mode { unsigned int data_lanes; };
struct ov08d10_lane_cfg { s64 link_freq_menu[2]; };
static const struct ov08d10_lane_cfg lane_cfg_2 = {{720000000, 360000000}};
struct ov08d10 {
	struct device *dev;
	const struct ov08d10_mode *cur_mode;
	const struct ov08d10_lane_cfg *priv_lane;
	unsigned int modes_size;
};
static struct device model_device;
static struct fwnode_handle model_node;
static bool model_debug, model_fwnode, model_endpoint;
static int model_parse_error;
static unsigned int model_lanes, model_frequencies, model_frees, model_puts;
static s64 model_link_frequencies[2];
#define dev_dbg(dev, format, ...) do { \
	if (model_debug) fprintf(stderr, format, __VA_ARGS__); \
} while (0)
#define dev_err(dev, format, ...) do { \
	if (model_debug) fprintf(stderr, format, ##__VA_ARGS__); \
} while (0)
static struct fwnode_handle *dev_fwnode(struct device *dev)
{
	(void)dev;
	return model_fwnode ? &model_node : NULL;
}
static struct fwnode_handle *fwnode_graph_get_next_endpoint(
	struct fwnode_handle *node, void *previous)
{
	(void)node; (void)previous;
	return model_endpoint ? &model_node : NULL;
}
static void fwnode_handle_put(struct fwnode_handle *node)
{
	assert(node == &model_node);
	model_puts++;
}
static int v4l2_fwnode_endpoint_alloc_parse(struct fwnode_handle *node,
	struct v4l2_fwnode_endpoint *endpoint)
{
	assert(node == &model_node);
	assert(endpoint->bus_type == V4L2_MBUS_CSI2_DPHY);
	endpoint->bus.mipi_csi2.num_data_lanes = model_lanes;
	endpoint->nr_of_link_frequencies = model_frequencies;
	endpoint->link_frequencies = model_link_frequencies;
	return model_parse_error;
}
static void v4l2_fwnode_endpoint_free(struct v4l2_fwnode_endpoint *endpoint)
{
	assert(endpoint->link_frequencies == model_link_frequencies);
	model_frees++;
}
static unsigned int ov08d10_modes_num(const struct ov08d10 *sensor)
{
	assert(sensor->priv_lane == &lane_cfg_2);
	return 3;
}

#include "sensor-hwcfg-function.c"

static void defaults(void)
{
	model_debug = true;
	model_fwnode = model_endpoint = true;
	model_parse_error = 0;
	model_lanes = 2;
	model_frequencies = 2;
	model_frees = model_puts = 0;
	model_link_frequencies[0] = 720000000;
	model_link_frequencies[1] = 360000000;
}

static void check(int expected, unsigned int puts, unsigned int frees)
{
	struct ov08d10 sensor = {.dev = &model_device};

	assert(sensor.cur_mode == NULL);
	assert(ov08d10_get_hwcfg(&sensor) == expected);
	assert(sensor.cur_mode == NULL);
	assert(model_puts == puts && model_frees == frees);
	if (!expected)
		assert(sensor.priv_lane == &lane_cfg_2 && sensor.modes_size == 3);
}

int main(void)
{
	defaults();
#ifdef SENSOR_BEFORE
	fputs("Before-control: debug enabled with unset current mode\n", stderr);
	check(0, 1, 1);
	return 0;
#else
	check(0, 1, 1);
	defaults(); model_debug = false; check(0, 1, 1);
	defaults(); model_fwnode = false; check(-ENXIO, 0, 0);
	defaults(); model_endpoint = false; check(-ENXIO, 0, 0);
	defaults(); model_parse_error = -ENOMEM; check(-ENOMEM, 1, 0);
	for (unsigned int lanes = 0; lanes <= 4; lanes++) {
		if (lanes == 2) continue;
		defaults(); model_lanes = lanes; check(-EINVAL, 1, 1);
	}
	defaults(); model_frequencies = 0; check(-EINVAL, 1, 1);
	defaults(); model_frequencies = 1; check(-EINVAL, 1, 1);
	defaults(); model_link_frequencies[1] = 1; check(-EINVAL, 1, 1);
	defaults(); model_link_frequencies[0] = 1; check(-EINVAL, 1, 1);
	defaults(); model_link_frequencies[0] = 360000000;
	model_link_frequencies[1] = 720000000; check(0, 1, 1);
	puts("OV08D10 actual hardware-config function: 14 cases passed");
	return 0;
#endif
}
