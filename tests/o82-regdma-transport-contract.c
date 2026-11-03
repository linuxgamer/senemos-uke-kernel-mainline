// SPDX-License-Identifier: GPL-2.0-only
/* Compile the actual kernel transport against deterministic MMIO, never hardware. */
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "dpu_hw_ctl.h"
#include "dpu_o82_regdma.h"
#include "linux/io.h"

#define BIT(n) (1U << (n))
#define FORCE (BIT(0) | BIT(16))
#define ERROR_MASK (7U | (15U << 16))

enum completion { DONE, TIMEOUT, ERROR, ERROR_AND_DONE, QUEUE1_ONLY };
static unsigned char registers[0x7000], control[0x200];
static enum completion outcome;
static unsigned int reset_count, fail_reset_from, trigger_count;
static unsigned int writes, reads, dma_barriers, io_barriers, status_reads;
static unsigned int address_write, command_write, status_clear;
static unsigned int selected_ctl;
static bool active, broken_clock, broken_error_clear, broken_done_clear;
static bool add_clock_bit;

static uint32_t load(const unsigned char *memory, size_t offset)
{
	uint32_t value;
	memcpy(&value, memory + offset, 4);
	return value;
}

static void store(unsigned char *memory, size_t offset, uint32_t value)
{
	memcpy(memory + offset, &value, 4);
}

uint32_t readl(const volatile void *address)
{
	uintptr_t at = (uintptr_t)address - (uintptr_t)registers;
	unsigned int base = selected_ctl * 0x1000;

	assert(at < sizeof(registers) - 3 && !(at & 3));
	reads++;
	if (at == base + 0x54 && (!fail_reset_from || reset_count < fail_reset_from)) {
		store(registers, at, 0);
		active = false;
	}
	if (at == base + 0x44 && active) {
		status_reads++;
		if (outcome == DONE && status_reads >= 3) {
			store(registers, at, BIT(3));
			active = false;
			if (add_clock_bit)
				store(registers, 0x1f0, load(registers, 0x1f0) | BIT(12));
		}
	}
	return load(registers, at);
}

void writel(uint32_t value, volatile void *address)
{
	uintptr_t at = (uintptr_t)address - (uintptr_t)registers;
	unsigned int base = selected_ctl * 0x1000;

	writes++;
	if ((uintptr_t)address == (uintptr_t)control + 0xd4) {
		assert(value == BIT(0));
		assert(dma_barriers == trigger_count + 1);
		assert(io_barriers == trigger_count + 1);
		assert(status_clear < address_write && address_write < command_write);
		assert(command_write < writes);
		assert((load(registers, 0x1f0) & FORCE) == FORCE);
		assert(!(load(registers, 0x170) & ERROR_MASK));
		assert(!load(registers, base + 0x54));
		trigger_count++;
		active = true;
		status_reads = 0;
		if (outcome == ERROR || outcome == ERROR_AND_DONE)
			store(registers, 0x170, BIT(19));
		if (outcome == ERROR_AND_DONE)
			store(registers, base + 0x44, BIT(3));
		if (outcome == QUEUE1_ONLY)
			store(registers, base + 0x44, BIT(4));
		return;
	}
	assert(at < sizeof(registers) - 3 && !(at & 3));
	if (at == base + 0x54)
		reset_count++;
	if (at == 0x1b0) {
		assert(value == ERROR_MASK);
		if (!broken_error_clear)
			store(registers, 0x170, load(registers, 0x170) & ~value);
		return;
	}
	if (at == base + 0x48) {
		assert(value == BIT(3));
		status_clear = writes;
		if (!broken_done_clear)
			store(registers, base + 0x44, load(registers, base + 0x44) & ~value);
		return;
	}
	if (at == base)
		address_write = writes;
	if (at == base + 4)
		command_write = writes;
	if (at == 0x1f0 && broken_clock)
		value &= ~BIT(0);
	store(registers, at, value);
}

void test_dma_wmb(void) { dma_barriers++; }
void test_wmb(void) { io_barriers++; }

static void fresh(struct dpu_o82_regdma *dma, struct dpu_hw_ctl *ctl, unsigned int index)
{
	memset(registers, 0, sizeof(registers));
	memset(control, 0, sizeof(control));
	selected_ctl = index;
	reset_count = fail_reset_from = trigger_count = writes = reads = 0;
	dma_barriers = io_barriers = status_reads = address_write = command_write = status_clear = 0;
	active = broken_clock = broken_error_clear = broken_done_clear = add_clock_bit = false;
	outcome = DONE;
	ctl->idx = index;
	ctl->hw.blk_addr = control;
	dpu_o82_regdma_init(dma, registers);
	assert(dpu_o82_regdma_can_unmap(dma));
}

int main(void)
{
	struct dpu_o82_regdma dma;
	struct dpu_hw_ctl ctl;
	unsigned int before, before_reads;

	/* Bounds refuse before MMIO or a DMA descriptor is written. */
	fresh(&dma, &ctl, 1);
	assert(dpu_o82_regdma_execute(NULL, &ctl, 0x1000, 8) == -EINVAL);
	assert(dpu_o82_regdma_execute(&dma, NULL, 0x1000, 8) == -EINVAL);
	assert(!dpu_o82_regdma_can_unmap(NULL));
	assert(dpu_o82_regdma_recover(NULL) == -EINVAL);
	for (unsigned int index = 0; index < 6; index += 5) {
		ctl.idx = index;
		assert(dpu_o82_regdma_execute(&dma, &ctl, 0x1000, 8) == -EINVAL);
	}
	ctl.idx = 1;
	const uint64_t bad_addresses[] = {0, 1, 0x1001, 0x100000000ULL};
	for (unsigned int i = 0; i < sizeof(bad_addresses) / sizeof(*bad_addresses); i++)
		assert(dpu_o82_regdma_execute(&dma, &ctl, bad_addresses[i], 8) == -EINVAL);
	const size_t bad_lengths[] = {0, 4, 9, 65536};
	for (unsigned int i = 0; i < sizeof(bad_lengths) / sizeof(*bad_lengths); i++)
		assert(dpu_o82_regdma_execute(&dma, &ctl, 0x1000, bad_lengths[i]) == -EINVAL);
	assert(dpu_o82_regdma_execute(&dma, &ctl, 0xffffff00ULL, 260) == -EINVAL);
	assert(!writes && !reads && !trigger_count);

	for (unsigned int index = 1; index <= 4; index++) {
		for (unsigned int clocks = 0; clocks < 4; clocks++) {
			uint32_t old = BIT(9) | (clocks & 1 ? BIT(0) : 0) |
				(clocks & 2 ? BIT(16) : 0);
			fresh(&dma, &ctl, index);
			store(registers, 0x1f0, old);
			store(registers, 0x170, ERROR_MASK);
			store(registers, index * 0x1000 + 0x44, BIT(3));
			add_clock_bit = true;
			assert(!dpu_o82_regdma_execute(&dma, &ctl, 0xffffff00ULL, 256));
			assert(!active && trigger_count == 1 && reset_count == 1);
			assert(dpu_o82_regdma_can_unmap(&dma));
			assert(load(registers, 0x1f0) == (old | BIT(12)));
			assert(load(registers, index * 0x1000) == 0xffffff00U);
			assert(load(registers, index * 0x1000 + 4) == (BIT(24) | BIT(22) | 64));
			before = writes;
			assert(!dpu_o82_regdma_recover(&dma));
			assert(writes == before);
		}
	}

	for (enum completion mode = TIMEOUT; mode <= QUEUE1_ONLY; mode++) {
		fresh(&dma, &ctl, 2);
		outcome = mode;
		assert(dpu_o82_regdma_execute(&dma, &ctl, 0x1000, 8) ==
			(mode == ERROR || mode == ERROR_AND_DONE ? -EIO : -ETIMEDOUT));
		assert(!active && reset_count == 2);
		assert(dpu_o82_regdma_can_unmap(&dma));
		assert(!load(registers, 0x1f0));
		assert(status_reads < 205);
	}

	/* A stuck reset never authorizes release or reuse of the submitted mapping. */
	fresh(&dma, &ctl, 3);
	outcome = TIMEOUT;
	fail_reset_from = 2;
	assert(dpu_o82_regdma_execute(&dma, &ctl, 0x1000, 8) == -ETIMEDOUT);
	assert(active && !dpu_o82_regdma_can_unmap(&dma));
	assert(load(registers, 0x1f0) == FORCE);
	before = writes;
	before_reads = reads;
	assert(dpu_o82_regdma_execute(&dma, &ctl, 0x2000, 8) == -EBUSY);
	assert(writes == before && reads == before_reads);
	assert(dpu_o82_regdma_recover(&dma) == -ETIMEDOUT);
	assert(!dpu_o82_regdma_can_unmap(&dma));
	fail_reset_from = 0;
	assert(!dpu_o82_regdma_recover(&dma));
	assert(!active && dpu_o82_regdma_can_unmap(&dma));
	assert(!load(registers, 0x1f0));

	/* Refuse an initial failed reset without exposing the new buffer to DMA. */
	fresh(&dma, &ctl, 4);
	fail_reset_from = 1;
	assert(dpu_o82_regdma_execute(&dma, &ctl, 0x1000, 8) == -ETIMEDOUT);
	assert(!trigger_count && !address_write && !dpu_o82_regdma_can_unmap(&dma));

	for (unsigned int fault = 0; fault < 3; fault++) {
		fresh(&dma, &ctl, 1);
		broken_clock = fault == 0;
		broken_error_clear = fault == 1;
		broken_done_clear = fault == 2;
		store(registers, 0x170, BIT(0));
		store(registers, 0x1044, BIT(3));
		assert(dpu_o82_regdma_execute(&dma, &ctl, 0x1000, 8) == -EIO);
		assert(!trigger_count && !address_write && dpu_o82_regdma_can_unmap(&dma));
	}
	puts("Actual Cliffs DB transport: bounds, ordering, all CTLs, clock ownership, faults, timeout and quarantine/recovery passed");
	return 0;
}
