/* SPDX-License-Identifier: GPL-2.0-only */
/* Actual stable/patched caller; modeled lane setup, link frequency and mux. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
typedef uint8_t u8;
typedef uint32_t u32;
typedef int64_t s64;
#define MSM_CSIPHY_PAD_SINK 0
#define dev_err(...) do { } while (0)
struct csiphy_lanes_cfg { u8 num_data; };
struct csi2_data { struct csiphy_lanes_cfg lane_cfg; };
struct csiphy_config { struct csi2_data *csi2; bool combo_mode; u8 csid_id; };
struct formats { const void *formats; unsigned nformats; };
static unsigned setup_calls, read_calls, write_calls, barrier_calls, link_calls;
static u8 selected_mask;
static s64 selected_link;
static int setup_result;
static u32 mux;
static u32 read_mux(void *address) { assert(address == &mux); read_calls++; return mux; }
static void write_mux(u32 value, void *address) { assert(address == &mux); write_calls++; mux = value; }
#define readl_relaxed(p) read_mux(p)
#define writel_relaxed(v, p) write_mux(v, p)
#define wmb() do { barrier_calls++; } while (0)
static s64 camss_get_link_freq(void *entity, u8 bpp, u8 lanes)
{
	assert(entity && bpp == 10 && lanes == 2); link_calls++; return selected_link;
}
static u8 csiphy_get_bpp(const void *format, unsigned count, u32 code)
{
	assert(!format && count == 1 && code == 42); return 10;
}
static u8 lane_mask(struct csiphy_lanes_cfg *lanes) { assert(lanes->num_data == 2); return selected_mask; }
struct before_device;
struct after_device;
static void before_setup(struct before_device *dev, struct csiphy_config *cfg, s64 link, u8 mask)
{ assert(dev && cfg && link == selected_link && mask == selected_mask); setup_calls++; }
static int after_setup(struct after_device *dev, struct csiphy_config *cfg, s64 link, u8 mask)
{ assert(dev && cfg && link == selected_link && mask == selected_mask); setup_calls++; return setup_result; }
struct before_ops {
	u8 (*get_lane_mask)(struct csiphy_lanes_cfg *);
	void (*lanes_enable)(struct before_device *, struct csiphy_config *, s64, u8);
};
struct after_ops {
	u8 (*get_lane_mask)(struct csiphy_lanes_cfg *);
	int (*lanes_enable)(struct after_device *, struct csiphy_config *, s64, u8);
};
struct before_res { const struct before_ops *hw_ops; const struct formats *formats; };
struct after_res { const struct after_ops *hw_ops; const struct formats *formats; };
struct fake_camss { void *dev; };
struct before_device {
	struct csiphy_config cfg;
	const struct before_res *res;
	struct { u32 code; } fmt[1];
	struct { int entity; } subdev;
	struct fake_camss *camss;
	void *base_clk_mux;
};
struct after_device {
	struct csiphy_config cfg;
	const struct after_res *res;
	struct { u32 code; } fmt[1];
	struct { int entity; } subdev;
	struct fake_camss *camss;
	void *base_clk_mux;
};
#define csiphy_device before_device
#define csiphy_stream_on before_stream_on
#include "before-stream.h"
#undef csiphy_device
#undef csiphy_stream_on
#define csiphy_device after_device
#define csiphy_stream_on after_stream_on
#include "after-stream.h"
#undef csiphy_device
#undef csiphy_stream_on
static void reset(void)
{
	setup_calls = read_calls = write_calls = barrier_calls = link_calls = 0;
	selected_mask = 0x85; selected_link = 720000000; setup_result = 0; mux = 0xa5;
}
int main(int argc, char **argv)
{
	static const struct formats formats = {NULL, 1};
	static const struct before_ops before_ops = {lane_mask, before_setup};
	static const struct after_ops after_ops = {lane_mask, after_setup};
	static const struct before_res before_res = {&before_ops, &formats};
	static const struct after_res after_res = {&after_ops, &formats};
	struct csi2_data lanes = {{2}};
	struct before_device before = {.cfg = {&lanes, false, 3}, .res = &before_res, .fmt = {{42}}};
	struct after_device after = {.cfg = {&lanes, false, 3}, .res = &after_res, .fmt = {{42}}};
	if (argc == 2 && !strcmp(argv[1], "before")) {
		reset(); setup_result = -EIO;
		int ret = before_stream_on(&before);
		assert(!ret && setup_calls == 1);
		fputs("Original stream caller reported success after refused PHY setup\n", stderr);
		assert(ret == -EIO);
	}
	assert(argc == 1);
	const int results[] = {0, -EINVAL, -EIO, -ERANGE, -EOPNOTSUPP};
	for (unsigned i = 0; i < sizeof(results) / sizeof(results[0]); i++) {
		reset(); setup_result = results[i];
		assert(after_stream_on(&after) == results[i]);
		assert(setup_calls == 1 && link_calls == 1 && !read_calls && !write_calls && !barrier_calls);
	}
	reset(); after.base_clk_mux = &mux; selected_mask = 0;
	assert(after_stream_on(&after) == -EINVAL);
	assert(!setup_calls && !link_calls && !read_calls && !write_calls && !barrier_calls && mux == 0xa5);
	reset(); selected_link = -EIO;
	assert(after_stream_on(&after) == -EINVAL && !setup_calls && !read_calls && !write_calls);
	for (unsigned combo = 0; combo < 2; combo++) for (unsigned route = 0; route < 2; route++) {
		u32 original, revised;

		before.cfg.combo_mode = after.cfg.combo_mode = combo;
		before.base_clk_mux = after.base_clk_mux = &mux;
		reset(); selected_mask = route ? 0x18 : 0x85;
		assert(!before_stream_on(&before)); original = mux;
		assert(read_calls == 1 && write_calls == 1 && barrier_calls == 1 && setup_calls == 1);
		reset(); selected_mask = route ? 0x18 : 0x85;
		assert(!after_stream_on(&after)); revised = mux;
		assert(original == revised && revised == (combo && route ? 0x35U : 0xa3U));
		assert(read_calls == 1 && write_calls == 1 && barrier_calls == 1 && setup_calls == 1);
	}
	puts("Actual PHY stream caller: five backend results preserved, zero-mask refusal before mux/link access, existing link error and four original mux routes pass");
	return 0;
}
