/* SPDX-License-Identifier: GPL-2.0-only */
/* Actual kernel helper/callbacks, mocked MMIO and time; no device access. */
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <limits.h>
typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int32_t s32;
typedef int64_t s64;
#define __iomem
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define BIT(n) (1U << (n))
#define CSIPHY_DEFAULT_PARAMS 0
#define CSIPHY_SETTLE_CNT_LOWER_BYTE 2
#define CSIPHY_DNP_PARAMS 4
#define CSIPHY_SKEW_CAL 7
#include "entry-type.h"
static unsigned char registers[0x2000];
struct event { unsigned offset, value, delay; };
static struct event events[256], expected[256];
static unsigned event_count, expected_count;
static bool oracle_mode;
static u32 final_value[0x2000 / 4];
static void record_write(u32 value, void *address)
{
	ptrdiff_t offset = (unsigned char *)address - registers;
	assert(offset >= 0 && offset < (ptrdiff_t)sizeof(registers) && !(offset % 4));
	if (oracle_mode) {
		assert(expected_count < ARRAY_SIZE(expected));
		expected[expected_count++] = (struct event){offset, value, 0};
	} else {
		assert(event_count < ARRAY_SIZE(events));
		events[event_count++] = (struct event){offset, value, 0};
		final_value[offset / 4] = value;
	}
}
#define writel(v, p) record_write(v, p)
#define writel_relaxed(v, p) record_write(v, p)
static void record_delay(unsigned delay)
{
	if (oracle_mode) {
		assert(expected_count < ARRAY_SIZE(expected));
		expected[expected_count++] = (struct event){0, 0, delay};
	} else {
		assert(event_count < ARRAY_SIZE(events));
		events[event_count++] = (struct event){0, 0, delay};
	}
}
#define udelay(v) record_delay(v)
#define usleep_range(lo, hi) do { assert((hi) == (lo) + 5); record_delay(lo); } while (0)
static u64 div_u64(u64 dividend, u32 divisor) { return dividend / divisor; }
struct fake_regs { const struct csiphy_lane_regs *lane_regs; int lane_array_size; };
struct csiphy_device { struct fake_regs *regs; void *base; };
#include "native-before.h"
#include "phy.h"
#include "oem-types.h"
#define CAM_DBG(...) do { } while (0)
#define cam_io_w_mb(v, p) record_write(v, p)
static struct { void *base_address; uint8_t is_3phase; } g_phy_data[1];
#include "oem-data.h"
/* Preserve the original kernel int/u32 loop under this stricter user-C build. */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wsign-compare"
#include "oem-common.h"
#pragma GCC diagnostic pop
static void oem_program_lanes(void *csiphybase, unsigned lane_enable,
			     unsigned settle_cnt, bool skew_cal_enable)
{
	unsigned i, cfg_size = ARRAY_SIZE(csiphy_2ph_v2_2_1_reg);
	struct csiphy_reg_t *reg_array = csiphy_2ph_v2_2_1_reg;

#include "oem-lanes.h"
}
static void clear(void)
{
	event_count = expected_count = 0;
	oracle_mode = false;
	memset(events, 0, sizeof(events));
	memset(expected, 0, sizeof(expected));
	memset(final_value, 0, sizeof(final_value));
}
static void expect_write(unsigned offset, unsigned value)
{
	assert(expected_count < ARRAY_SIZE(expected));
	expected[expected_count++] = (struct event){offset, value, 0};
}
static void expect_delay(unsigned delay)
{
	assert(expected_count < ARRAY_SIZE(expected));
	expected[expected_count++] = (struct event){0, 0, delay};
}
static void mission_oracle(const struct csiphy_sm7675_config *config)
{
	unsigned mask = 128;
	u8 settle = csiphy_settle_cnt_calc(config->link_frequency, config->timer_rate);

	for (unsigned i = 0; i < config->num_lanes; i++)
		mask += 1U << (config->lanes[i] * 2);
	oracle_mode = true;
	for (unsigned i = 0; i < ARRAY_SIZE(csiphy_reset_enter_reg_2_2_1); i++) {
		struct csiphy_reg_t *entry = &csiphy_reset_enter_reg_2_2_1[i];
		record_write(entry->reg_data, registers + entry->reg_addr);
		if (entry->delay) record_delay(entry->delay);
	}
	record_write(mask, registers + 0x1014);
	g_phy_data[0].base_address = registers;
	assert(!__csiphy_prgm_common_data(0, csiphy_common_reg_2_2_1,
		ARRAY_SIZE(csiphy_common_reg_2_2_1), false));
	oem_program_lanes(registers, mask, settle, config->skew_calibration);
	oracle_mode = false;
	/* Native deliberately masks PHY IRQs; frames complete through CSID. */
	for (unsigned i = 0; i < 11; i++) expect_write(0x102c + i * 4, 0);
	for (unsigned i = 0; i < ARRAY_SIZE(csiphy_reset_exit_reg_2_2_1); i++) {
		struct csiphy_reg_t *entry = &csiphy_reset_exit_reg_2_2_1[i];

		if (entry->csiphy_param_type != OEM_CSIPHY_2PH_REGS) continue;
		expect_write(entry->reg_addr, entry->reg_data);
		if (entry->delay) expect_delay(entry->delay);
	}
}
static unsigned cases;
static void permutations(struct csiphy_sm7675_config *config, unsigned position, unsigned used)
{
	if (position < config->num_lanes) {
		for (unsigned i = 0; i < 4; i++) if (!(used & BIT(i))) {
			config->lanes[position] = i;
			permutations(config, position + 1, used | BIT(i));
		}
		return;
	}
	static const u64 frequencies[] = {360000000, 480000000, 560000000, 720000000};
	for (unsigned f = 0; f < ARRAY_SIZE(frequencies); f++) for (unsigned skew = 0; skew < 2; skew++) {
		u8 mask = 0, settle = 0;

		clear(); config->link_frequency = frequencies[f]; config->skew_calibration = skew;
		assert(!csiphy_sm7675_parameters(config, &mask, &settle));
		assert(settle == csiphy_settle_cnt_calc(config->link_frequency, config->timer_rate));
		mission_oracle(config);
		assert(!csiphy_sm7675_program(registers, config));
		assert(event_count == expected_count);
		assert(!memcmp(events, expected, event_count * sizeof(events[0])));
		assert(final_value[0x1014 / 4] == mask && final_value[0x1000 / 4] == 2);
		assert(final_value[0x94 / 4] == (skew ? 0xd7U : 0));
		cases++;
	}
}
static void refusal(struct csiphy_sm7675_config config, int error)
{
	clear(); assert(csiphy_sm7675_program(registers, &config) == error); assert(!event_count);
}
int main(int argc, char **argv)
{
	struct csiphy_sm7675_config config = {2, {0, 1, 0, 0}, 720000000, 400000000, false};

	if (argc == 2 && !strcmp(argv[1], "before")) {
		struct fake_regs regs = {csiphy_sm7675_dphy, ARRAY_SIZE(csiphy_sm7675_dphy)};
		struct csiphy_device phy = {&regs, registers};

		clear(); csiphy_gen2_config_lanes(&phy, csiphy_settle_cnt_calc(config.link_frequency, config.timer_rate));
		assert(final_value[0x94 / 4] == 7);
		fputs("Original generic CSIPHY skipped the required zero skew writes\n", stderr);
		assert(final_value[0x94 / 4] == 0);
	}
	assert(argc == 1);
	for (unsigned lanes = 1; lanes <= 4; lanes++) {config.num_lanes = lanes; permutations(&config, 0, 0);}
	assert(cases == 512);
	printf("Uke D-PHY: %u lane-permutation/rate/skew traces and stable valid settle equations passed; MMIO/time modeled\n", cases);
	config = (struct csiphy_sm7675_config){2, {0, 1}, 720000000, 400000000, false};
	clear(); assert(csiphy_sm7675_program(NULL, &config) == -EINVAL); assert(!event_count);
	assert(csiphy_sm7675_program(registers, NULL) == -EINVAL); assert(!event_count);
	struct csiphy_sm7675_config bad = config;
	bad.num_lanes = 0; refusal(bad, -EINVAL); bad.num_lanes = 5; refusal(bad, -EINVAL);
	bad = config; bad.lanes[1] = 0; refusal(bad, -EINVAL); bad.lanes[1] = 4; refusal(bad, -EINVAL);
	bad = config; bad.timer_rate = 0; refusal(bad, -EINVAL); bad.timer_rate = 399999999; refusal(bad, -EINVAL);
	bad = config; bad.link_frequency = 0; refusal(bad, -EINVAL); bad.link_frequency = 750000001; refusal(bad, -EINVAL);
	bad.link_frequency = UINT64_MAX; refusal(bad, -EINVAL); bad.link_frequency = 1; refusal(bad, -ERANGE);
	bad.link_frequency = 500000; refusal(bad, -ERANGE);
	u8 mask = 17, settle = 19;
	assert(csiphy_sm7675_parameters(&config, NULL, &settle) == -EINVAL && settle == 19);
	assert(csiphy_sm7675_parameters(&config, &mask, NULL) == -EINVAL && mask == 17);
	clear(); csiphy_sm7675_stop(registers);
	expect_write(0x1014, 0); expect_write(0x1000, 1); expect_delay(1);
	expect_write(0x1084, 0); expect_write(0x108c, 0); expect_delay(1);
	expect_write(0x101c, 0); expect_write(0x1018, 0);
	assert(event_count == expected_count && !memcmp(events, expected, event_count * sizeof(events[0])));
	puts("Uke D-PHY: invalid/null/overflow/timing refusal precedes MMIO; stop disables lanes and retains reset before common power-off");
	return 0;
}
