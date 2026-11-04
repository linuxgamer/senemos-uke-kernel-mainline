// SPDX-License-Identifier: GPL-2.0-only
/* Compile the actual kernel transport against deterministic MMIO, never hardware. */
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "dpu_hw_ctl.h"
#include "dpu_o82_regdma.h"
#include "dpu_o82_upload.h"
#include "dpu_o82_lutbus.h"
#include "dpu_o82_profiles.h"
#include "o82-hsic-format.h"
#include "o82-memory-format.h"
#include "msm_gem.h"
#include "linux/io.h"
#include "dpu_kms.h"
#include "dpu_o82_power.h"
#include "dpu_o82_platform.h"
#include "shared-helpers.h"

#define BIT(n) (1U << (n))
#define FORCE (BIT(0) | BIT(16))
#define ERROR_MASK (7U | (15U << 16))

enum completion { DONE, TIMEOUT, ERROR, ERROR_AND_DONE, QUEUE1_ONLY };
static unsigned char registers[0x7000], control[0x200];
static unsigned char mdp_registers[0x400], vbif_registers[0x1000];
static unsigned char pa_mmio[0x5a000], sixzone_data[O82_SIXZONE_BYTES];
static unsigned char memory_data[O82_MEMORY_BYTES];
static unsigned int expected_command_mask = 3, pa_reads, dropped_pa_reg;
static int dropped_pa_dspp = -1;
static enum completion outcome;
static unsigned int reset_count, fail_reset_from, trigger_count;
static unsigned int writes, reads, dma_barriers, io_barriers, status_reads;
static unsigned int address_write, command_write, status_clear;
static unsigned int selected_ctl;
static bool active, broken_clock, broken_error_clear, broken_done_clear;
static bool add_clock_bit;
static struct dpu_o82_regdma *command_owner;
static struct dpu_kms *command_kms;
static bool emulate_power_hold;
static bool broken_mdp_enable, broken_mdp_release, broken_pmu_release;
static unsigned int dropped_qos_offset;
static int runtime_usage, pm_get_error, pm_put_error;
static unsigned int pm_gets, pm_puts, pm_noresume, suspend_callbacks;
static unsigned int power_case;
static bool halt_blocked, halt_wrong_half, unhalt_blocked, dropped_halt;
static bool require_rearm, detached;
static unsigned int reset_queues, close_sleeps, close_errors, detach_count;
static struct drm_gem_object command_bo;
static unsigned char commands[DPU_O82_LUTBUS_MAX_BYTES];
static unsigned int allocations, releases;
static int allocation_error;
static u64 allocation_iova = 0x1000;

static void dpu_o82_color_fini(struct dpu_kms *kms)
{
	struct dpu_o82_regdma *dma = kms->o82_regdma;

	assert(dma && dma->closing && !dma->command_bo && !dma->power_held);
	assert(dpu_o82_regdma_can_unmap(dma));
}

struct drm_gpuvm *drm_gpuvm_get(struct drm_gpuvm *vm)
{
	assert(command_owner->lock.locked && vm->references);
	vm->references++;
	return vm;
}

void drm_gpuvm_put(struct drm_gpuvm *vm)
{
	if (detached && vm->references == 1) {
		assert(!command_owner->lock.locked && !command_owner->command_bo);
		vm->references--;
		return;
	}
	assert(command_owner->lock.locked && vm->references == 2);
	vm->references--;
}

bool drm_gpuvm_range_valid(struct drm_gpuvm *vm, u64 address, u64 bytes)
{
	assert(command_owner->lock.locked && vm->references == 2);
	return address >= 0x1000 && address < 0x100000000ULL && bytes &&
		bytes <= 0x100000000ULL - address;
}

void *msm_gem_kernel_new(struct drm_device *drm, size_t bytes, u32 flags,
			 struct drm_gpuvm *vm, struct drm_gem_object **bo, u64 *iova)
{
	assert(command_owner->lock.locked && vm->references == 2);
	assert(bytes == sizeof(commands) && flags == MSM_BO_WC);
	assert(!command_owner->command_bo);
	allocations++;
	if (allocation_error)
		return (void *)(intptr_t)allocation_error;
	command_bo.dev = drm;
	*bo = &command_bo;
	*iova = allocation_iova;
	return commands;
}

void msm_gem_kernel_put(struct drm_gem_object *bo, struct drm_gpuvm *vm)
{
	assert(command_owner->lock.locked && vm->references == 2);
	assert(bo == &command_bo);
	assert((!active && !command_owner->quarantined_ctl) || command_owner->bus_isolated);
	releases++;
}

static void upload_lifetime(void);
static void power_lifetime(void);

int pm_runtime_resume_and_get(struct device *dev)
{
	assert(dev == &command_kms->pdev->dev && command_owner->power_lock.locked);
	assert(command_owner->power_held);
	/* A forced suspend while resume is pending must not release clocks. */
	assert(dpu_o82_platform_suspend(command_kms) == -EBUSY);
	pm_gets++;
	if (pm_get_error) return pm_get_error;
	runtime_usage++;
	return 0;
}

int pm_runtime_put_sync(struct device *dev)
{
	assert(dev == &command_kms->pdev->dev && command_owner->power_lock.locked);
	assert(!command_owner->power_held && !command_owner->mdp_clock_owned);
	assert(!command_owner->pmu_clock_owned && (!active || command_owner->bus_isolated) && runtime_usage > 0);
	pm_puts++; runtime_usage--;
	if (pm_put_error) return pm_put_error;
	if (!runtime_usage) {
		suspend_callbacks++;
		return dpu_o82_platform_suspend(command_kms);
	}
	return 0;
}

void pm_runtime_get_noresume(struct device *dev)
{
	assert(dev == &command_kms->pdev->dev && command_owner->power_lock.locked);
	pm_noresume++; runtime_usage++;
}

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

static void setup_memory(unsigned int enabled, unsigned int protection)
{
	memset(memory_data,0,sizeof(memory_data));
	store(memory_data,0,enabled);store(memory_data,4,protection);store(memory_data,8,1);
	for(unsigned int i=0;i<3;i++) {
		if(!(enabled&BIT(i)))continue;
		unsigned int at=16+32*i;
		store(memory_data,at,8);store(memory_data,at+4,0x7fff8001+i);
		store(memory_data,at+8,0x20002000);store(memory_data,at+12,0x400000);
		store(memory_data,at+16,1+5*i);store(memory_data,at+20,0x03000300);
		store(memory_data,at+24,0x000800ff);store(memory_data,at+28,0x000800e0);
	}
	assert(o82_memory_valid(memory_data,sizeof(memory_data)));
}

static void test_detach(struct msm_mmu *mmu)
{
	assert(mmu && command_owner && command_kms);
	if (command_owner->command_bo || command_owner->command_vm ||
	    command_owner->power_held || command_owner->mdp_clock_owned ||
	    command_owner->pmu_clock_owned ||
	    (!command_owner->bus_isolated && (active || command_owner->quarantined_ctl))) {
		fputs("Expected negative control: MMU detach still owns REGDMA resources\n", stderr);
		abort();
	}
	assert(command_owner->closing && !command_owner->power_lock.locked);
	if (command_owner->quarantined_ctl)
		assert((load(vbif_registers, 0x200) & BIT(7)) &&
		       (load(vbif_registers, 0x204) & BIT(23)));
	detached = true;
	detach_count++;
}

static void msleep(unsigned int milliseconds)
{
	assert(milliseconds == 20 && !command_owner->power_lock.locked);
	assert(command_owner->closing && command_owner->power_held);
	assert(command_owner->command_bo && command_owner->command_vm->references == 2);
	assert(!releases && !detach_count && runtime_usage == 2);
	assert(load(mdp_registers, 0x2bc) & BIT(20));
	assert((load(registers, 0x1f0) & FORCE) == FORCE);
	close_sleeps++;
	if (close_sleeps == 2)
		halt_blocked = halt_wrong_half = dropped_halt = false;
}

static void test_drain_error(struct device *dev, int error)
{
	assert(dev == &command_kms->pdev->dev && error < 0);
	close_errors++;
}

/* Interpret actual commands, including preserved-field modifies on each DSPP. */
static void apply_pa_commands(void)
{
	const unsigned int bases[] = { 0x54000, 0x56000, 0x58000 };
	unsigned int at = 0, mask = 0;
	unsigned int length = (load(registers, selected_ctl * 0x1000 + 4) & 0x3fff) * 4;

	if (!command_owner || !command_owner->command_bo || !command_kms || !command_kms->mmio)
		return;
	assert(length <= sizeof(commands) && command_owner->lock.locked);
	while (at < length) {
		unsigned int op = load(commands, at); at += 4;

		if (!op) continue;
		assert(at + 4 <= length);
		if (op == 0x18180114) { mask = load(commands, at) >> 17; at += 4; continue; }
		unsigned int value = load(commands, at); at += 4;
		if ((op >> 28) == 6) { at += ((value >> 16) & 255) * (value & 65535) * 4; continue; }
		if ((op >> 28) == 3) { at += value * 4; continue; }
		assert((op >> 28) == 1 || (op >> 28) == 2);
		unsigned int reg = op & 0xfffff, preserve = 0;
		if ((op >> 28) == 2) { preserve = value; value = load(commands, at); at += 4; }
		if (reg != 0x800 && reg != 0x840 && reg != 0x920 && (reg < 0x81c || reg > 0x828) &&
		    (reg < 0x908 || reg > 0x918) && (reg < 0x880 || reg > 0x8d0)) continue;
		for (unsigned int i = 0; i < 3; i++) {
			if (!(mask & BIT(i)) || ((int)i == dropped_pa_dspp && reg == dropped_pa_reg)) continue;
			store(pa_mmio, bases[i] + reg, (load(pa_mmio, bases[i] + reg) & preserve) | value);
		}
	}
	assert(at == length);
}

uint32_t readl(const volatile void *address)
{
	uintptr_t at = (uintptr_t)address - (uintptr_t)registers;
	unsigned int base = selected_ctl * 0x1000;

	if ((uintptr_t)address >= (uintptr_t)pa_mmio &&
	    (uintptr_t)address < (uintptr_t)pa_mmio + sizeof(pa_mmio)) {
		assert(command_owner->power_lock.locked && runtime_usage > 0 && command_owner->power_held);
		assert(load(mdp_registers, 0x2bc) & BIT(20));
		assert((load(registers, 0x1f0) & FORCE) == FORCE);
		pa_reads++;
		return load(pa_mmio, (uintptr_t)address - (uintptr_t)pa_mmio);
	}
	if ((uintptr_t)address >= (uintptr_t)mdp_registers &&
	    (uintptr_t)address < (uintptr_t)mdp_registers + sizeof(mdp_registers)) {
		reads++; return load(mdp_registers, (uintptr_t)address - (uintptr_t)mdp_registers);
	}
	if ((uintptr_t)address >= (uintptr_t)vbif_registers &&
	    (uintptr_t)address < (uintptr_t)vbif_registers + sizeof(vbif_registers)) {
		reads++; return load(vbif_registers, (uintptr_t)address - (uintptr_t)vbif_registers);
	}
	assert(at < sizeof(registers) - 3 && !(at & 3));
	reads++;
	if (at >= 0x1000 && at <= 0x4054 && at % 0x1000 == 0x54 &&
	    (!fail_reset_from || reset_count < fail_reset_from)) {
		store(registers, at, 0);
		reset_queues |= BIT(at / 0x1000);
		if (at == base + 0x54)
			active = false;
	}
	if (at == base + 0x44 && active) {
		status_reads++;
		if (outcome == DONE && status_reads >= 3) {
			apply_pa_commands();
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
	if ((uintptr_t)address >= (uintptr_t)mdp_registers &&
	    (uintptr_t)address < (uintptr_t)mdp_registers + sizeof(mdp_registers)) {
		size_t offset = (uintptr_t)address - (uintptr_t)mdp_registers;
		assert(dpu_hw_clock_lock && offset == 0x2bc);
		if (broken_mdp_enable && (value & BIT(20))) value &= ~BIT(20);
		if (broken_mdp_release && !(value & BIT(20))) value |= BIT(20);
		store(mdp_registers, offset, value); return;
	}
	if ((uintptr_t)address >= (uintptr_t)vbif_registers &&
	    (uintptr_t)address < (uintptr_t)vbif_registers + sizeof(vbif_registers)) {
		size_t offset = (uintptr_t)address - (uintptr_t)vbif_registers;
		assert(command_owner->power_lock.locked);
		assert(runtime_usage > 0 && command_owner->power_held);
		assert(load(mdp_registers, 0x2bc) & BIT(20));
		assert((load(registers, 0x1f0) & FORCE) == FORCE);
		if (offset == 0x200) {
			assert(dpu_vbif_halt_lock && !dpu_vbif_qos_lock);
			assert((value & ~BIT(7)) == (load(vbif_registers, offset) & ~BIT(7)));
			if (dropped_halt) return;
			store(vbif_registers, offset, value);
			u32 status = load(vbif_registers, 0x204);
			if (value & BIT(7)) {
				if (!halt_blocked && !halt_wrong_half) status |= BIT(23);
				if (halt_wrong_half) status |= BIT(7); /* Never a valid Uke ACK. */
			} else {
				if (require_rearm) assert((reset_queues & 0x1e) == 0x1e);
				if (!unhalt_blocked) status &= ~BIT(23);
			}
			store(vbif_registers, 0x204, status);
			return;
		}
		assert(dpu_vbif_qos_lock && !dpu_vbif_halt_lock);

		if (offset != dropped_qos_offset) store(vbif_registers, offset, value);
		return;
	}
	if ((uintptr_t)address == (uintptr_t)control + 0xd4) {
		assert(value == BIT(0));
		if (command_kms && !emulate_power_hold) {
			assert(runtime_usage > 0 && command_owner->power_held);
			assert(load(mdp_registers, 0x2bc) & BIT(20));
			assert(!(load(vbif_registers, 0x200) & BIT(7)));
			assert(!(load(vbif_registers, 0x204) & BIT(23)) && !command_owner->bus_isolated);
			for (unsigned int level = 0; level < 8; level++) {
				unsigned int expected = level < 4 ? 4 : 5;
				if (((load(vbif_registers, 0x550 + 8 * level) >> 28) & 7) != expected ||
				    ((load(vbif_registers, 0x590 + 8 * level) >> 28) & 7) != expected)
					fprintf(stderr, "Synthetic QoS before trigger: case=%u row=%u RP=%u LVL=%u expected=%u\n",
						power_case, level, (load(vbif_registers, 0x550 + 8 * level) >> 28) & 7,
						(load(vbif_registers, 0x590 + 8 * level) >> 28) & 7, expected);
				assert(((load(vbif_registers, 0x550 + 8 * level) >> 28) & 7) == expected);
				assert(((load(vbif_registers, 0x590 + 8 * level) >> 28) & 7) == expected);
			}
		}
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
	if (at >= 0x1000 && at <= 0x4054 && at % 0x1000 == 0x54)
		reset_count++;
	if (at == 0x1b0) {
		assert(value == ERROR_MASK);
		if (!broken_error_clear)
			store(registers, 0x170, load(registers, 0x170) & ~value);
		return;
	}
	if (at >= 0x1000 && at <= 0x4048 && at % 0x1000 == 0x48) {
		assert(value == BIT(3));
		status_clear = writes;
		if (!broken_done_clear)
			store(registers, at - 4, load(registers, at - 4) & ~value);
		return;
	}
	if (at == base)
		address_write = writes;
	if (at == base + 4)
		command_write = writes;
	if (at == 0x1f0 && broken_clock)
		value &= ~BIT(0);
	if (at == 0x1f0 && broken_pmu_release && (load(registers, at) & FORCE) == FORCE &&
	    (value & FORCE) != FORCE)
		value |= FORCE;
	store(registers, at, value);
}

void test_dma_wmb(void)
{
	if (command_owner && command_owner->command_bo) {
		assert(command_owner->lock.locked);
		assert(load(commands, 0) == 0x18180114);
		assert(load(commands, 4) == (expected_command_mask << 17));
	}
	dma_barriers++;
}
void test_wmb(void) { io_barriers++; }

static void fresh(struct dpu_o82_regdma *dma, struct dpu_hw_ctl *ctl, unsigned int index)
{
	memset(registers, 0, sizeof(registers));
	memset(control, 0, sizeof(control));
	memset(mdp_registers, 0, sizeof(mdp_registers));
	memset(pa_mmio, 0, sizeof(pa_mmio));
	pa_reads = 0; dropped_pa_dspp = -1; dropped_pa_reg = 0; expected_command_mask = 3;
	memset(vbif_registers, 0x33, sizeof(vbif_registers));
	store(vbif_registers, 0x200, BIT(2));
	store(vbif_registers, 0x204, BIT(2));
	store(mdp_registers, 0x2bc, BIT(12));
	assert(!dpu_hw_clock_lock && !dpu_vbif_qos_lock && !dpu_vbif_halt_lock);
	halt_blocked = halt_wrong_half = unhalt_blocked = dropped_halt = false;
	require_rearm = detached = false;
	reset_queues = close_sleeps = close_errors = detach_count = 0;
	broken_mdp_enable = broken_mdp_release = broken_pmu_release = false;
	dropped_qos_offset = 0;
	runtime_usage = 1; pm_get_error = pm_put_error = 0;
	pm_gets = pm_puts = pm_noresume = suspend_callbacks = 0;
	selected_ctl = index;
	reset_count = fail_reset_from = trigger_count = writes = reads = 0;
	dma_barriers = io_barriers = status_reads = address_write = command_write = status_clear = 0;
	active = broken_clock = broken_error_clear = broken_done_clear = add_clock_bit = false;
	outcome = DONE;
	ctl->idx = index;
	ctl->hw.blk_addr = control;
	dpu_o82_regdma_init(dma, registers);
	if (command_owner == dma && command_kms) {
		dma->kms_owner = command_kms;
		command_kms->o82_regdma = dma;
		dma->power_held = emulate_power_hold;
	}
	assert(dpu_o82_regdma_can_unmap(dma));
}

int main(void)
{
	setvbuf(stdout, NULL, _IONBF, 0);
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
	upload_lifetime();
	power_lifetime();
	return 0;
}

static void upload_lifetime(void)
{
	static u8 igc[257 * 3 * 2], gamut[4913 * 3 * 2], gc[1024 * 3 * 2];
	struct dpu_o82_color_input input = { .igc = igc, .gamut = gamut, .gc = gc };
	struct dpu_o82_regdma dma;
	struct dpu_hw_ctl ctl;
	struct drm_device drm = {1}, foreign_drm = {2};
	struct drm_gpuvm vm = { .references = 1, .drm = &drm, .managed = true };
	struct drm_gpuvm foreign_vm = { .references = 1, .drm = &foreign_drm, .managed = true };
	struct dpu_kms kms = { .dev = &drm, .base = {.vm = &vm} };
	unsigned int before;

	for (unsigned int channel = 0; channel < 3; channel++) {
		igc[2 * (256 * 3 + channel)] = 0xff;
		igc[2 * (256 * 3 + channel) + 1] = 0x0f;
	}
	command_owner = &dma;
	command_kms = &kms; emulate_power_hold = true;
	for (unsigned int fault = 0; fault < 3; fault++) {
		fresh(&dma, &ctl, 1);
		allocations = releases = 0;
		allocation_error = fault == 0 ? -ENOMEM : fault == 1 ? -ENOSPC : -EIO;
		assert(dpu_o82_upload(&dma, &drm, &vm, &ctl, &input, 3) == allocation_error);
		assert(allocations == 1 && !releases && vm.references == 1);
		assert(!dma.command_bo && !dma.command_vm && !writes && !reads);
	}
	allocation_error = 0;
	const u64 invalid[] = {0, 1, 0x100, 0x1001, 0x100000000ULL, 0xffffff00ULL};
	for (unsigned int i = 0; i < sizeof(invalid) / sizeof(*invalid); i++) {
		fresh(&dma, &ctl, 1);
		allocations = releases = 0; allocation_iova = invalid[i];
		assert(dpu_o82_upload(&dma, &drm, &vm, &ctl, &input, 3) == -EINVAL);
		assert(allocations == 1 && releases == 1 && vm.references == 1);
		assert(!dma.command_bo && !dma.command_vm && !writes && !reads);
	}
	allocation_iova = 0x1000;
	fresh(&dma, &ctl, 1); allocations = releases = 0;
	assert(dpu_o82_upload(NULL, &drm, &vm, &ctl, &input, 3) == -EINVAL);
	assert(dpu_o82_upload(&dma, NULL, &vm, &ctl, &input, 3) == -EINVAL);
	assert(dpu_o82_upload(&dma, &drm, NULL, &ctl, &input, 3) == -EINVAL);
	assert(dpu_o82_upload(&dma, &drm, &vm, NULL, &input, 3) == -EINVAL);
	assert(dpu_o82_upload(&dma, &drm, &vm, &ctl, NULL, 3) == -EINVAL);
	assert(dpu_o82_upload(&dma, &drm, &vm, &ctl, &input, 1) == -EINVAL);
	assert(dpu_o82_upload(&dma, &foreign_drm, &vm, &ctl, &input, 3) == -EINVAL);
	assert(!allocations && !writes && !reads);
	vm.managed = false;
	assert(dpu_o82_upload(&dma, &drm, &vm, &ctl, &input, 3) == -EINVAL);
	vm.managed = true;
	dma.power_held = false;
	assert(dpu_o82_upload(&dma, &drm, &vm, &ctl, &input, 3) == -EHOSTDOWN);
	dma.power_held = true;
	assert(!allocations && !writes && !reads);
	assert(dpu_o82_upload_release(NULL) == -EINVAL);
	assert(!dpu_o82_upload_release(&dma));
	assert(!dpu_o82_upload(&dma, &drm, &vm, &ctl, &input, 3));
	assert(dma.command_bo == &command_bo && dma.command_vm == &vm);
	assert(dma.command_data == commands && dma.command_iova == 0x1000);
	assert(allocations == 1 && !releases && vm.references == 2 && trigger_count == 1);
	/* The allocated buffer also fits PA; this legacy input emits only base LUTs. */
	assert(load(registers, 0x1004) == ((1U << 24) | (1U << 22) | (37316U / 4)));
	before = writes + reads;
	assert(dpu_o82_upload(&dma, &foreign_drm, &vm, &ctl, &input, 3) == -EINVAL);
	foreign_vm.drm = &drm;
	assert(dpu_o82_upload(&dma, &drm, &foreign_vm, &ctl, &input, 3) == -EINVAL);
	foreign_vm.drm = &foreign_drm;
	assert(dpu_o82_regdma_execute(&dma, &ctl, dma.command_iova, sizeof(commands)) == -EBUSY);
	gc[1] = 4; /* The actual LUT encoder rejects a 1024-valued GC entry. */
	assert(dpu_o82_upload(&dma, &drm, &vm, &ctl, &input, 3) == -EINVAL);
	gc[1] = 0;
	assert(writes + reads == before && allocations == 1 && !releases);
	assert(foreign_vm.references == 1 && vm.references == 2);
	assert(!dpu_o82_upload(&dma, &drm, &vm, &ctl, &input, 3));
	assert(allocations == 1 && trigger_count == 2 && vm.references == 2);

	outcome = TIMEOUT; fail_reset_from = reset_count + 2;
	assert(dpu_o82_upload(&dma, &drm, &vm, &ctl, &input, 3) == -ETIMEDOUT);
	assert(active && dma.quarantined_ctl && vm.references == 2);
	before = writes + reads;
	assert(dpu_o82_upload_release(&dma) == -EBUSY);
	assert(dpu_o82_upload(&dma, &drm, &vm, &ctl, &input, 3) == -EBUSY);
	assert(dpu_o82_regdma_execute(&dma, &ctl, 0x2000, 8) == -EBUSY);
	assert(!releases && allocations == 1 && vm.references == 2 && writes + reads == before);
	fail_reset_from = 0;
	assert(!dpu_o82_regdma_recover(&dma) && !active);
	assert(vm.references == 2 && !releases); /* Recovery alone does not drop memory. */
	assert(!dpu_o82_upload_release(&dma));
	assert(releases == 1 && vm.references == 1 && !dma.command_bo && !dma.command_vm);
	assert(!dma.command_data && !dma.command_iova);
	assert(!dpu_o82_upload_release(&dma) && releases == 1);

	/* Reallocation remains bound to the admitted KMS and its managed VM. */
	outcome = ERROR;
	assert(dpu_o82_upload(&dma, &drm, &vm, &ctl, &input, 3) == -EIO);
	assert(!dma.quarantined_ctl && !active && vm.references == 2);
	assert(!dpu_o82_upload_release(&dma));
	assert(vm.references == 1 && foreign_vm.references == 1 && releases == 2 && allocations == 2);
	command_owner = NULL;
	command_kms = NULL; emulate_power_hold = false;
	puts("Actual O82 GEM/transport/encoder: WC allocation, balanced VM references, mapping bounds, reuse, foreign/raw refusal, malformed LUT, failed-stop retention, recovery and release passed; fake providers only");
}

static bool clock_control(struct dpu_hw_mdp *mdp, unsigned int clock, bool enable)
{
	assert(clock == DPU_CLK_CTRL_REG_DMA);
	return dpu_hw_clk_force_ctrl(&mdp->hw, &mdp->caps->clk_ctrls[clock], enable);
}

static void power_lifetime(void)
{
	static u8 igc[257 * 3 * 2], gamut[4913 * 3 * 2], gc[1024 * 3 * 2];
	struct dpu_o82_color_input input = { .igc = igc, .gamut = gamut, .gc = gc };
	struct dpu_o82_regdma dma;
	struct dpu_hw_ctl ctl;
	struct drm_device drm = {1};
	struct drm_gpuvm vm = { .references = 1, .drm = &drm, .managed = true };
	struct platform_device pdev = { .dev = {1} };
	struct dpu_mdp_cfg mdp_cfg;
	struct dpu_vbif_cfg vbif_cfg;
	struct dpu_hw_mdp mdp;
	struct dpu_hw_vbif vbif;
	struct dpu_kms kms;
	const struct msm_mmu_funcs mmu_funcs = { .detach = test_detach };
	struct msm_mmu mmu = { .funcs = &mmu_funcs };
	unsigned int before;

	for (unsigned int channel = 0; channel < 3; channel++) {
		igc[2 * (256 * 3 + channel)] = 0xff;
		igc[2 * (256 * 3 + channel) + 1] = 0x0f;
	}
	command_owner = &dma; command_kms = &kms; emulate_power_hold = false;
	vm.mmu = &mmu;
#define RESET_POWER() do { \
	power_case++; \
	assert(vm.references == 1); \
	mdp_cfg = (struct dpu_mdp_cfg){ .clk_ctrls = {[DPU_CLK_CTRL_REG_DMA] = {0x2bc,20}} }; \
	vbif_cfg = (struct dpu_vbif_cfg){ .qos_rp_remap_size = 0x40, .xin_halt_timeout = 0x4000 }; \
	mdp = (struct dpu_hw_mdp){ .hw = {mdp_registers}, .caps = &mdp_cfg, .ops = {clock_control} }; \
	vbif = (struct dpu_hw_vbif){ .hw = {vbif_registers}, .cap = &vbif_cfg, \
		.ops = {dpu_hw_set_qos_remap, dpu_hw_set_halt_ctrl} }; \
	kms = (struct dpu_kms){ .dev=&drm, .pdev=&pdev, .base={.vm=&vm}, .hw_mdp=&mdp, .hw_vbif=&vbif }; \
	vm.managed = true; fresh(&dma, &ctl, 1); allocations = releases = 0; \
} while (0)
	for (unsigned int fault = 0; fault < 9; fault++) {
		RESET_POWER();
		if (fault == 0) dma.kms_owner = NULL;
		if (fault == 1) kms.base.vm = NULL;
		if (fault == 2) vm.managed = false;
		if (fault == 3) mdp.ops.setup_clk_force_ctrl = NULL;
		if (fault == 4) mdp_cfg.clk_ctrls[DPU_CLK_CTRL_REG_DMA].reg_off++;
		if (fault == 5) vbif_cfg.qos_rp_remap_size = 0x20;
		if (fault == 6) vbif.ops.set_qos_remap = NULL;
		if (fault == 7) vbif.ops.set_halt_ctrl = NULL;
		if (fault == 8) vbif_cfg.xin_halt_timeout = 0;
		assert(dpu_o82_power_upload(&kms, &ctl, &input, 3) == -EINVAL);
		assert(!pm_gets && !pm_puts && !allocations && !reads && !writes);
	}
	RESET_POWER();
	struct dpu_kms alias = kms;
	assert(dpu_o82_power_upload(&alias, &ctl, &input, 3) == -EINVAL);
	assert(!pm_gets && !allocations);
	pm_get_error = -EACCES;
	assert(dpu_o82_power_upload(&kms, &ctl, &input, 3) == -EACCES);
	assert(pm_gets == 1 && !pm_puts && runtime_usage == 1 && !dma.power_held);
	assert(!reads && !writes && !allocations);
	RESET_POWER(); broken_mdp_enable = true;
	assert(dpu_o82_power_upload(&kms, &ctl, &input, 3) == -EIO);
	assert(pm_gets == 1 && pm_puts == 1 && runtime_usage == 1 && !dma.power_held);
	assert(!allocations && !trigger_count);
	RESET_POWER(); broken_clock = true;
	assert(dpu_o82_power_upload(&kms, &ctl, &input, 3) == -EIO);
	assert(pm_puts == 1 && runtime_usage == 1 && !dma.power_held && !allocations);
	assert(!(load(mdp_registers, 0x2bc) & BIT(20)) && !(load(registers, 0x1f0) & FORCE));
	for (unsigned int matrix = 0; matrix < 2; matrix++) {
		RESET_POWER(); dropped_qos_offset = (matrix ? 0x590 : 0x550) + 8 * 3;
		assert(dpu_o82_power_upload(&kms, &ctl, &input, 3) == -EIO);
		assert(!allocations && !trigger_count && pm_puts == 1 && !dma.power_held);
	}
	RESET_POWER();
	assert(!dpu_o82_power_upload(&kms, &ctl, &input, 3));
	assert(runtime_usage == 1 && pm_gets == 1 && pm_puts == 1 && vm.references == 2);
	assert(!dma.power_held && !dma.mdp_clock_owned && !dma.pmu_clock_owned);
	assert(load(mdp_registers, 0x2bc) == BIT(12));
	for (unsigned int level = 0; level < 8; level++) {
		u32 mask = 7U << 28;
		assert((load(vbif_registers, 0x550 + 8 * level) & ~mask) == (0x33333333U & ~mask));
		assert((load(vbif_registers, 0x590 + 8 * level) & ~mask) == (0x33333333U & ~mask));
	}
	assert(!dpu_o82_upload_release(&dma) && vm.references == 1);
	RESET_POWER();
	store(mdp_registers, 0x2bc, BIT(12) | BIT(20));
	store(registers, 0x1f0, FORCE | BIT(9));
	assert(!dpu_o82_power_upload(&kms, &ctl, &input, 3));
	assert(load(mdp_registers, 0x2bc) == (BIT(12) | BIT(20)));
	assert(load(registers, 0x1f0) == (FORCE | BIT(9)) && !dma.power_held);
	assert(!dpu_o82_upload_release(&dma));
	RESET_POWER(); outcome = TIMEOUT; fail_reset_from = 2;
	assert(dpu_o82_power_upload(&kms, &ctl, &input, 3) == -ETIMEDOUT);
	assert(dma.power_held && runtime_usage == 2 && !pm_puts && vm.references == 2);
	assert(dpu_o82_platform_suspend(&kms) == -EBUSY);
	before = writes + reads;
	assert(dpu_o82_power_upload(&kms, &ctl, &input, 3) == -EBUSY);
	assert(dpu_o82_regdma_execute(&dma, &ctl, 0x2000, 8) == -EBUSY);
	assert(pm_gets == 1 && writes + reads == before && !releases);
	assert(dpu_o82_power_recover(&kms) == -ETIMEDOUT && runtime_usage == 2 && !pm_puts);
	fail_reset_from = 0;
	assert(!dpu_o82_power_recover(&kms));
	assert(!dma.power_held && runtime_usage == 1 && pm_puts == 1 && vm.references == 2);
	assert(!dpu_o82_upload_release(&dma));
	for (unsigned int clock = 0; clock < 2; clock++) {
		RESET_POWER();
		broken_mdp_release = clock == 0; broken_pmu_release = clock == 1;
		assert(dpu_o82_power_upload(&kms, &ctl, &input, 3) == -EIO);
		assert(dma.power_held && runtime_usage == 2 && !pm_puts && !dma.quarantined_ctl);
		assert(dpu_o82_platform_suspend(&kms) == -EBUSY);
		broken_mdp_release = broken_pmu_release = false;
		assert(!dpu_o82_power_recover(&kms));
		assert(runtime_usage == 1 && pm_puts == 1 && !dma.power_held);
		assert(!dpu_o82_upload_release(&dma));
	}
	RESET_POWER(); pm_put_error = -EBUSY;
	assert(dpu_o82_power_upload(&kms, &ctl, &input, 3) == -EBUSY);
	assert(dma.power_held && runtime_usage == 2 && pm_puts == 1 && pm_noresume == 1);
	assert(dpu_o82_platform_suspend(&kms) == -EBUSY);
	pm_put_error = 0;
	assert(!dpu_o82_power_recover(&kms) && runtime_usage == 1 && pm_puts == 2);
	assert(!dpu_o82_upload_release(&dma));
	RESET_POWER(); runtime_usage = 0;
	assert(!dpu_o82_power_upload(&kms, &ctl, &input, 3));
	assert(!runtime_usage && suspend_callbacks == 1 && !dma.command_bo && vm.references == 1);
	assert(!dpu_o82_power_recover(&kms) && pm_puts == 1);

	/* Idle/probe unwind closes admission without touching uninitialized MMIO. */
	RESET_POWER();
	assert(!dpu_o82_power_close(&kms) && dma.closing && !reads && !writes);
	assert(dpu_o82_power_upload(&kms, &ctl, &input, 3) == -ESHUTDOWN);
	assert(dpu_o82_upload(&dma, &drm, &vm, &ctl, &input, 3) == -ESHUTDOWN);
	assert(dpu_o82_regdma_execute(&dma, &ctl, 0x2000, 8) == -ESHUTDOWN);
	assert(dpu_o82_power_recover(&kms) == -ESHUTDOWN);
	assert(!reads && !writes && !pm_gets);
	_dpu_kms_mmu_destroy(&kms);
	assert(detach_count == 1 && vm.references == 0 && !kms.base.vm);
	_dpu_kms_mmu_destroy(&kms);
	assert(detach_count == 1 && !reads && !writes);
	vm.references = 1;

	RESET_POWER();
	assert(!dpu_o82_power_upload(&kms, &ctl, &input, 3));
	before = reads + writes;
	_dpu_kms_mmu_destroy(&kms);
	assert(reads + writes == before && releases == 1 && vm.references == 0 && detach_count == 1);
	vm.references = 1;

	/* A successful reset needs no bus halt; actual detach follows all cleanup. */
	RESET_POWER(); outcome = TIMEOUT; fail_reset_from = 2;
	assert(dpu_o82_power_upload(&kms, &ctl, &input, 3) == -ETIMEDOUT);
	if (getenv("O82_UNSAFE_DETACH")) {
		_dpu_kms_mmu_destroy_before(&kms);
		assert(!"The former detach path must fail the ownership guard");
	}
	fail_reset_from = 0;
	_dpu_kms_mmu_destroy(&kms);
	assert(!dma.bus_isolated && !active && releases == 1 && vm.references == 0);
	assert(!dma.power_held && runtime_usage == 1 && detach_count == 1 && !close_sleeps);
	assert(load(vbif_registers, 0x200) == BIT(2));
	vm.references = 1;

	for (unsigned int fault = 0; fault < 3; fault++) {
		RESET_POWER(); outcome = TIMEOUT; fail_reset_from = 2;
		assert(dpu_o82_power_upload(&kms, &ctl, &input, 3) == -ETIMEDOUT);
		halt_blocked = fault == 0; halt_wrong_half = fault == 1; dropped_halt = fault == 2;
		assert(dpu_o82_power_close(&kms) == (fault == 2 ? -EIO : -ETIMEDOUT));
		assert(dma.closing && !dma.bus_isolated && dma.power_held && dma.command_bo);
		assert(active && dma.quarantined_ctl && vm.references == 2 && !releases && !detach_count);
		assert(runtime_usage == 2 && !pm_puts && !dpu_o82_regdma_can_unmap(&dma));
		assert(dpu_o82_platform_suspend(&kms) == -EBUSY);
		if (fault == 1) assert((load(vbif_registers, 0x204) & BIT(7)) &&
					!(load(vbif_registers, 0x204) & BIT(23)));
		_dpu_kms_mmu_destroy(&kms); /* Fake sleeps admit ACK only on the third attempt. */
		assert(close_sleeps == 2 && close_errors == 2 && detach_count == 1);
		assert(dma.bus_isolated && dma.quarantined_ctl && !dma.command_bo && !dma.power_held);
		assert(releases == 1 && vm.references == 0 && runtime_usage == 1 && pm_puts == 1);
		assert(load(vbif_registers, 0x200) == (BIT(2) | BIT(7)));
		assert(load(vbif_registers, 0x204) & BIT(23));
		vm.references = 1;
	}

	/* A later owner must reset every old DB queue while xin7 is still halted. */
	dpu_o82_regdma_init(&dma, registers);
	dma.kms_owner = &kms; kms.base.vm = &vm;
	require_rearm = true; reset_queues = 0; fail_reset_from = 0; outcome = DONE;
	assert(!dpu_o82_power_upload(&kms, &ctl, &input, 3));
	assert((reset_queues & 0x1e) == 0x1e && !dma.bus_isolated && !dma.quarantined_ctl);
	assert(load(vbif_registers, 0x200) == BIT(2) && !(load(vbif_registers, 0x204) & BIT(23)));
	assert(trigger_count == 2 && allocations == 2 && vm.references == 2);
	_dpu_kms_mmu_destroy(&kms);
	assert(releases == 2 && vm.references == 0 && detach_count == 2);
	vm.references = 1;

	for (unsigned int fault = 0; fault < 2; fault++) {
		RESET_POWER(); require_rearm = true;
		store(vbif_registers, 0x200, BIT(2) | BIT(7));
		store(vbif_registers, 0x204, BIT(2) | BIT(23));
		if (fault == 0) fail_reset_from = 1;
		if (fault == 1) unhalt_blocked = true;
		assert(dpu_o82_power_upload(&kms, &ctl, &input, 3) == -ETIMEDOUT);
		assert(!allocations && !trigger_count && !dma.power_held && dma.bus_isolated);
		assert(vm.references == 1 && runtime_usage == 1 && pm_puts == 1);
		if (fault == 0) assert(load(vbif_registers, 0x200) & BIT(7));
		fail_reset_from = 0; unhalt_blocked = false;
		assert(!dpu_o82_power_upload(&kms, &ctl, &input, 3));
		assert(!dma.bus_isolated && !dma.quarantined_ctl && trigger_count == 1);
		_dpu_kms_mmu_destroy(&kms);
		assert(releases == 1 && vm.references == 0);
		vm.references = 1;
	}
	/* Actual PA snapshot, command interpretation and control-readback boundaries. */
	struct dpu_dspp_cfg dspp_cfg[3];
	struct dpu_mdss_cfg catalog;
	const unsigned int pa_bases[] = { 0x54000, 0x56000, 0x58000 };
	const unsigned int pa_regs[] = { 0x800, 0x840, 0x908, 0x90c, 0x910, 0x914, 0x918, 0x920, 0x81c, 0x820, 0x824, 0x828 };
	unsigned char hsic_data[O82_HSIC_BYTES];
	memset(sixzone_data, 0, sizeof(sixzone_data));
	store(sixzone_data, 0, 15); store(sixzone_data, 4, 0xe5cc3319);
	store(sixzone_data, 8, 0x160c); store(sixzone_data, 12, 0x0ba21555);
	store(sixzone_data, 16, 0x3a359b33); store(sixzone_data, 20, 0x046904d4);
	sixzone_data[24] = 1; sixzone_data[25] = 2; store(sixzone_data, 28, 384);
	assert(o82_sixzone_valid(sixzone_data, sizeof(sixzone_data)));
#define SETUP_PA() do { \
	input.pa_managed = true; input.sixzone = sixzone_data; input.sixzone_bytes = sizeof(sixzone_data); \
	input.memory = NULL; input.memory_bytes = 0; \
	memset(hsic_data, 0, sizeof(hsic_data)); store(hsic_data,0,15); store(hsic_data,4,0xb3); \
	store(hsic_data,8,0x7f20); store(hsic_data,12,0x20); store(hsic_data,16,0xe0); \
	input.hsic = hsic_data; input.hsic_bytes = sizeof(hsic_data); \
	for (unsigned int pi = 0; pi < 3; pi++) { \
		dspp_cfg[pi] = (struct dpu_dspp_cfg){DSPP_0 + pi, pa_bases[pi], 0x1800}; \
		store(pa_mmio, pa_bases[pi] + 0x800, 0x24100101 | (pi ? BIT(5) : 0)); \
		store(pa_mmio, pa_bases[pi] + 0x840, 0xaaaa0123 + pi * 0x100); \
		for (unsigned int pj = 2; pj < 12; pj++) \
			store(pa_mmio, pa_bases[pi] + pa_regs[pj], 0xa5000000 | pi << 12 | pa_regs[pj]); \
		for (unsigned int pj = 0; pj < 21; pj++) \
			store(pa_mmio, pa_bases[pi]+0x880+4*pj, 0xa5000000 | pi << 12 | (0x880+4*pj)); \
		input.pa_mode[pi] = 0xdeadbeef; input.pa_hold[pi] = 0xdeadbeef; \
	} \
	catalog = (struct dpu_mdss_cfg){3,dspp_cfg}; kms.catalog = &catalog; kms.mmio = pa_mmio; \
} while (0)
	for (unsigned int fault = 0; fault < 8; fault++) {
		RESET_POWER(); SETUP_PA();
		if (fault == 0) kms.mmio = NULL;
		if (fault == 1) kms.catalog = NULL;
		if (fault == 2) catalog.dspp = NULL;
		if (fault == 3) catalog.dspp_count = 2;
		if (fault == 4) dspp_cfg[0].id++;
		if (fault == 5) dspp_cfg[1].base++;
		if (fault == 6) dspp_cfg[2].len--;
		if (fault == 7) dspp_cfg[2].id--;
		assert(dpu_o82_power_upload(&kms, &ctl, &input, 3) == -EINVAL);
		assert(!pa_reads && !allocations && !trigger_count && !dma.power_held && runtime_usage == 1);
	}
	for (unsigned int defect=0;defect<8;defect++) {
		RESET_POWER(); SETUP_PA();
		if (defect==0) input.hsic=NULL;
		if (defect==1) input.hsic_bytes--;
		if (defect==2) store(hsic_data,0,1);
		if (defect==3) store(hsic_data,4,0x1000);
		if (defect==4) store(hsic_data,8,0x10000);
		if (defect==5) store(hsic_data,12,0x100);
		if (defect==6) store(hsic_data,20,1);
		if (defect==7) store(hsic_data,0,0);
		assert(dpu_o82_power_upload(&kms,&ctl,&input,3)==-EINVAL);
		assert(!pa_reads && !allocations && !trigger_count && !dma.power_held && runtime_usage==1);
	}
	const unsigned int pa_masks[] = {3,5,6}, hsic_words[] = {0xb3,0x7f20,0x20,0xe0};
	for (unsigned int m=0;m<3;m++) for (unsigned int enable=0;enable<2;enable++)
	for (unsigned int hsic_on=0;hsic_on<2;hsic_on++) {
		RESET_POWER(); SETUP_PA(); expected_command_mask=pa_masks[m];
		if (!enable) {input.sixzone=NULL;input.sixzone_bytes=0;}
		if (!hsic_on) memset(hsic_data,0,sizeof(hsic_data));
		unsigned char original[sizeof(input)]; memcpy(original,&input,sizeof(input));
		assert(!dpu_o82_power_upload(&kms,&ctl,&input,pa_masks[m]));
		assert(load(registers,0x1004)==((1U<<24)|(1U<<22)|((enable?41320U:37388U)/4)));
		assert(!memcmp(original,&input,sizeof(input)));
		assert(pa_reads==(enable?28u:16u) && trigger_count==1 && !dma.power_held);
		for (unsigned int i=0;i<3;i++) {
			const unsigned int mode=load(pa_mmio,pa_bases[i]+0x800);
			const unsigned int hold=load(pa_mmio,pa_bases[i]+0x840);
			if (!(pa_masks[m]&BIT(i))) {
				assert(mode==(0x24100101|(i?BIT(5):0)));
				assert(hold==0xaaaa0123+i*0x100);
			} else {
				const unsigned int owned=(enable?0xe0000000u:0)|(hsic_on?0x1e000000u:0);
				assert(mode==(0x101|(i?0x20:0)|owned|((i||owned)?0x100000:0)));
				assert(hold==(enable?0x9123+i*0x100:0xaaaa0123+i*0x100));
				for (unsigned int j=0;j<4;j++) assert(load(pa_mmio,pa_bases[i]+0x81c+4*j)==(hsic_on?hsic_words[j]:0));
			}
		}
		_dpu_kms_mmu_destroy(&kms);assert(releases==1&&vm.references==0);vm.references=1;
	}
	for (unsigned int half = 0; half < 2; half++) for (unsigned int reg = 0; reg < 12; reg++) {
		RESET_POWER(); SETUP_PA(); dropped_pa_dspp = half; dropped_pa_reg = pa_regs[reg];
		assert(dpu_o82_power_upload(&kms, &ctl, &input, 3) == -EIO);
		assert(trigger_count == 1 && !dma.power_held && runtime_usage == 1);
		_dpu_kms_mmu_destroy(&kms); assert(releases == 1 && vm.references == 0); vm.references = 1;
	}
	for (unsigned int half=0;half<2;half++) for (unsigned int reg=8;reg<12;reg++) {
		RESET_POWER(); SETUP_PA(); memset(hsic_data,0,sizeof(hsic_data));
		dropped_pa_dspp=half;dropped_pa_reg=pa_regs[reg];
		assert(dpu_o82_power_upload(&kms,&ctl,&input,3)==-EIO);
		assert(trigger_count==1&&!dma.power_held&&runtime_usage==1);
		_dpu_kms_mmu_destroy(&kms);assert(releases==1&&vm.references==0);vm.references=1;
	}
	const unsigned int protections[]={0,1,2,4,8,16,32,63};
	const unsigned int protection_modes[]={0,0x400000,0x800000,0x1000000,0x40000,0x20000,8,0x1c60008};
	const unsigned int region_modes[]={0x20,0x80,0x40};
	unsigned int memory_cases=0;
	for(unsigned int m=0;m<3;m++)for(unsigned int six=0;six<2;six++)
	for(unsigned int hsic_on=0;hsic_on<2;hsic_on++)for(unsigned int enabled=0;enabled<8;enabled++)
	for(unsigned int prot=0;prot<8;prot++) {
		RESET_POWER();SETUP_PA();setup_memory(enabled,protections[prot]);
		input.memory=memory_data;input.memory_bytes=sizeof(memory_data);expected_command_mask=pa_masks[m];
		if(!six){input.sixzone=NULL;input.sixzone_bytes=0;}
		if(!hsic_on)memset(hsic_data,0,sizeof(hsic_data));
		unsigned char original[sizeof(input)];memcpy(original,&input,sizeof(input));
		assert(!dpu_o82_power_upload(&kms,&ctl,&input,pa_masks[m]));
		assert(load(registers,0x1004)==((1U<<24)|(1U<<22)|((six?41488U:37580U)/4)));
		assert(!memcmp(original,&input,sizeof(input)));
		assert(pa_reads==(six?70U:58U)&&trigger_count==1&&!dma.power_held&&runtime_usage==1);
		unsigned int owned=(six?0xe0000000U:0)|(hsic_on?0x1e000000U:0)|protection_modes[prot],hold=0;
		for(unsigned int i=0;i<3;i++)if(enabled&BIT(i)){owned|=region_modes[i];hold|=(1+5*i)<<(4*i);}
		for(unsigned int half=0;half<3;half++) {
			if(!(pa_masks[m]&BIT(half))) {
				assert(load(pa_mmio,pa_bases[half]+0x800)==(0x24100101|(half?BIT(5):0)));
				assert(load(pa_mmio,pa_bases[half]+0x840)==0xaaaa0123+half*0x100);
				for(unsigned int j=0;j<21;j++)
					assert(load(pa_mmio,pa_bases[half]+0x880+4*j)==(0xa5000000|half<<12|(0x880+4*j)));
				continue;
			}
			assert(load(pa_mmio,pa_bases[half]+0x800)==(0x101|owned|(owned?0x100000:0)));
			assert(load(pa_mmio,pa_bases[half]+0x840)==(hold|(six?0x9000:0)));
			for(unsigned int i=0;i<3;i++) {
				unsigned int at=16+32*i;
				const unsigned int offsets[]={0,4,20,24,28,8,12};
				const unsigned int regs[]={0x880+20*i,0x884+20*i,0x888+20*i,0x88c+20*i,
					0x890+20*i,0x8bc+8*i,0x8c0+8*i};
				for(unsigned int j=0;j<7;j++)assert(load(pa_mmio,pa_bases[half]+regs[j])==load(memory_data,at+offsets[j]));
			}
		}
		_dpu_kms_mmu_destroy(&kms);assert(releases==1&&vm.references==0);vm.references=1;memory_cases++;
	}
	for(unsigned int enabled=0;enabled<2;enabled++)for(unsigned int half=0;half<2;half++)
	for(unsigned int reg=0;reg<21;reg++) {
		RESET_POWER();SETUP_PA();setup_memory(enabled?7:0,63);
		input.memory=memory_data;input.memory_bytes=sizeof(memory_data);
		dropped_pa_dspp=half;dropped_pa_reg=0x880+4*reg;
		assert(dpu_o82_power_upload(&kms,&ctl,&input,3)==-EIO);
		assert(trigger_count==1&&!dma.power_held&&runtime_usage==1);
		_dpu_kms_mmu_destroy(&kms);assert(releases==1&&vm.references==0);vm.references=1;
	}
	for(unsigned int defect=0;defect<7;defect++) {
		RESET_POWER();SETUP_PA();setup_memory(7,63);
		input.memory=memory_data;input.memory_bytes=sizeof(memory_data);
		if(defect==0)input.memory=NULL;
		if(defect==1)input.memory_bytes--;
		if(defect==2)store(memory_data,0,8);
		if(defect==3)store(memory_data,4,64);
		if(defect==4)store(memory_data,8,2);
		if(defect==5)store(memory_data,28,0);
		if(defect==6)input.pa_managed=false;
		assert(dpu_o82_power_upload(&kms,&ctl,&input,3)==-EINVAL);
		assert(!pa_reads&&!allocations&&!trigger_count&&!dma.power_held&&runtime_usage==1);
	}
	RESET_POWER();SETUP_PA();setup_memory(7,63);input.memory=memory_data;input.memory_bytes=sizeof(memory_data);
	outcome=TIMEOUT;fail_reset_from=1;
	assert(dpu_o82_power_upload(&kms,&ctl,&input,3)==-ETIMEDOUT);
	assert(pa_reads==4&&dma.power_held&&dma.command_bo&&vm.references==2);
	fail_reset_from=0;_dpu_kms_mmu_destroy(&kms);assert(releases==1&&vm.references==0);vm.references=1;
	printf("Actual memory/protection power path: %u paired mode/hold cases, all21 register readbacks, both-half ignored active/neutral writes, malformed refusal and failed-stop retention passed; fake MMIO only\n",memory_cases);
	RESET_POWER(); SETUP_PA(); outcome = TIMEOUT; fail_reset_from = 1;
	assert(dpu_o82_power_upload(&kms, &ctl, &input, 3) == -ETIMEDOUT);
	assert(pa_reads == 4 && dma.power_held && dma.command_bo && vm.references == 2);
	fail_reset_from = 0;
	_dpu_kms_mmu_destroy(&kms); assert(releases == 1 && vm.references == 0); vm.references = 1;
#undef SETUP_PA
#undef RESET_POWER
	command_owner = NULL; command_kms = NULL;
	puts("Actual O82 power/GEM/transport/shared helpers: bound managed VM, pending-resume suspend refusal, both force gates, exact eight-level LUTDMA QoS/readbacks, preserved client fields, failed-stop/clock/PM retention, recovery and suspend-before-clock memory release passed; fake providers only");
	puts("Actual KMS MMU detach: closed admission, reset or exact upper-half xin7 ACK before GEM/VM/power release, retained ownership across failed attempts, four-queue rearm before unhalt and failed-rearm refusal passed; fake providers only");
	puts("Actual composed PA: malformed HSIC/catalog refusal, owned snapshots, HSIC/SixZone combinations across all DSPP pairs, explicit neutral words, foreign-state preservation, both-half ignored-write refusal and failed-stop retention passed; fake providers only");
}
