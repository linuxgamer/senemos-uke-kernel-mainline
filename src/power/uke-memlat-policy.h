/* SPDX-License-Identifier: GPL-2.0-only */
/* Qualcomm MEMLAT sampling/ceiling-map policy, adapted to bounded perf samples.
 * OEM algorithm: MiCode 5712080a, drivers/soc/qcom/dcvs/memlat.c.
 * Copyright (c) 2020-2021, The Linux Foundation. All rights reserved.
 * Copyright (c) 2022-2023 Qualcomm Innovation Center, Inc. All rights reserved.
 */
#ifndef UKE_MEMLAT_POLICY_H
#define UKE_MEMLAT_POLICY_H

#define UKE_MEMLAT_CPUS 8
#define UKE_MEMLAT_ROWS 12
#define UKE_MEMLAT_EVENTS 4
#define UKE_MEMLAT_IPM_CEIL 400

struct uke_memlat_row {
	u32 cpu_khz;
	u32 memory_khz;
};

struct uke_memlat_count {
	u64 value, enabled, running;
};

static bool uke_memlat_delta(const struct uke_memlat_count *now,
			    const struct uke_memlat_count *before, u64 *delta)
{
	u64 enabled, running;

	if (now->value < before->value || now->enabled < before->enabled ||
	    now->running < before->running)
		return false;
	enabled = now->enabled - before->enabled;
	running = now->running - before->running;
	/* Never scale an unscheduled or multiplexed counter into a policy vote. */
	if (!enabled || running != enabled)
		return false;
	*delta = now->value - before->value;
	return true;
}

static bool uke_memlat_map_valid(const struct uke_memlat_row *map, unsigned int rows,
				u32 maximum)
{
	unsigned int i;

	if (!rows || rows > UKE_MEMLAT_ROWS)
		return false;
	for (i = 0; i < rows; i++)
		if (!map[i].cpu_khz || map[i].cpu_khz > 5000000 ||
		    !map[i].memory_khz || map[i].memory_khz > maximum ||
		    (i && (map[i].cpu_khz <= map[i - 1].cpu_khz ||
			   map[i].memory_khz < map[i - 1].memory_khz)))
			return false;
	return true;
}

static u32 uke_memlat_vote(const struct uke_memlat_row *map, unsigned int rows,
			  bool compute, u64 instructions, u64 cycles,
			  u64 misses, u64 elapsed_ns)
{
	u64 mhz;
	unsigned int i;

	/* Discard stalled workers, counter resets, idle intervals and impossible rates. */
	if (!rows || rows > UKE_MEMLAT_ROWS || elapsed_ns < 100000 || elapsed_ns > 1000000000 || !cycles ||
	    cycles > elapsed_ns * 5 ||
	    (!compute && (!misses || div64_u64(instructions, misses) > UKE_MEMLAT_IPM_CEIL)))
		return 0;
	mhz = div64_u64(cycles * 1000, elapsed_ns);
	if (!mhz)
		return 0;
	/* Match the OEM ceiling table, including its integer-MHz conversion. */
	for (i = 0; i + 1 < rows && map[i].cpu_khz / 1000 < mhz; i++)
		;
	return map[i].memory_khz;
}
#endif
