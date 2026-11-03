// SPDX-License-Identifier: GPL-2.0-only
/*
 * LLCC-v2 register protocol derived from MiCode Uke qcom_llcc_pmu.c.
 * Copyright (c) 2017-2020, The Linux Foundation. All rights reserved.
 * Copyright (c) 2022-2023, Qualcomm Innovation Center, Inc. All rights reserved.
 * Native perf ownership, validated CPU mapping and bounded polling for SM7675.
 */
#include <linux/cpu_pm.h>
#include <linux/hrtimer.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/perf_event.h>
#include <linux/platform_device.h>
#include <linux/pm.h>

#define LLCC_CPUS 8
#define LLCC_CFG 0x200
#define LLCC_COUNT(n) (0x220 + 4 * (n))
#define LLCC_EVENT 0x1000
#define LLCC_MASK GENMASK(23, 0)
/* shortcut: polling cannot recover multiple wraps, qualify the maximum rate and timer latency before policy use. */
#define LLCC_POLL_NS NSEC_PER_MSEC

struct sm7675_llcc_pmu {
	struct pmu pmu;
	void __iomem *base;
	raw_spinlock_t lock;
	struct perf_event *events[LLCC_CPUS];
	u8 bank[LLCC_CPUS];
	struct hrtimer timer;
	struct notifier_block cpu_pm;
	unsigned int active, idle;
	bool suspended, removing;
};

static struct sm7675_llcc_pmu *to_llcc(struct pmu *pmu)
{
	return container_of(pmu, struct sm7675_llcc_pmu, pmu);
}

static void llcc_enable(struct sm7675_llcc_pmu *p, unsigned int bank, bool enable)
{
	u32 value = readl(p->base + LLCC_CFG);

	if (enable)
		value |= BIT(bank);
	else
		value &= ~BIT(bank);
	writel(value, p->base + LLCC_CFG);
}

static void llcc_clear(struct sm7675_llcc_pmu *p, unsigned int bank)
{
	u32 value = readl(p->base + LLCC_CFG) & ~BIT(16 + bank);

	writel(value | BIT(16 + bank), p->base + LLCC_CFG);
	writel(value, p->base + LLCC_CFG);
}

/* The lock serializes timer/perf/PM readers around freeze, read and clear. */
static void llcc_update(struct sm7675_llcc_pmu *p, struct perf_event *event, bool restart)
{
	unsigned int bank = p->bank[event->cpu];
	u32 value;

	if ((event->hw.state & PERF_HES_STOPPED) || p->suspended || (p->idle & BIT(event->cpu)))
		return;
	llcc_enable(p, bank, false);
	value = readl(p->base + LLCC_COUNT(bank)) & LLCC_MASK;
	local64_add((u64)value << 3, &event->count);
	llcc_clear(p, bank);
	if (restart)
		llcc_enable(p, bank, true);
}

static enum hrtimer_restart llcc_poll(struct hrtimer *timer)
{
	struct sm7675_llcc_pmu *p = container_of(timer, struct sm7675_llcc_pmu, timer);
	unsigned long flags;
	unsigned int cpu;
	bool again;

	raw_spin_lock_irqsave(&p->lock, flags);
	again = p->active && !p->suspended && !p->removing;
	if (again) {
		for (cpu = 0; cpu < LLCC_CPUS; cpu++)
			if (p->events[cpu])
				llcc_update(p, p->events[cpu], true);
		hrtimer_forward_now(timer, ns_to_ktime(LLCC_POLL_NS));
	}
	raw_spin_unlock_irqrestore(&p->lock, flags);
	return again ? HRTIMER_RESTART : HRTIMER_NORESTART;
}

static int llcc_event_init(struct perf_event *event)
{
	if (event->attr.type != event->pmu->type)
		return -ENOENT;
	if (event->cpu < 0 || event->cpu >= LLCC_CPUS || !cpu_possible(event->cpu) ||
	    (event->attach_state & PERF_ATTACH_TASK) || event->attr.config != LLCC_EVENT ||
	    event->attr.config1 || event->attr.config2 || has_branch_stack(event))
		return -EINVAL;
	if (is_sampling_event(event) || event->attr.exclude_user || event->attr.exclude_kernel ||
	    event->attr.exclude_hv || event->attr.exclude_idle ||
	    event->attr.exclude_host || event->attr.exclude_guest)
		return -EOPNOTSUPP;
	event->hw.idx = -1;
	return 0;
}

static void llcc_start_locked(struct sm7675_llcc_pmu *p, struct perf_event *event)
{
	if (!(event->hw.state & PERF_HES_STOPPED) || p->removing)
		return;
	event->hw.state = 0;
	if (!p->suspended && !(p->idle & BIT(event->cpu))) {
		llcc_clear(p, p->bank[event->cpu]);
		llcc_enable(p, p->bank[event->cpu], true);
	}
	if (!p->active++ && !p->suspended)
		hrtimer_start(&p->timer, ns_to_ktime(LLCC_POLL_NS), HRTIMER_MODE_REL);
}

static void llcc_stop_locked(struct sm7675_llcc_pmu *p, struct perf_event *event)
{
	if (event->hw.state & PERF_HES_STOPPED)
		return;
	llcc_update(p, event, false);
	event->hw.state = PERF_HES_STOPPED | PERF_HES_UPTODATE;
	p->active--;
}

static void llcc_start(struct perf_event *event, int flags)
{
	struct sm7675_llcc_pmu *p = to_llcc(event->pmu);
	unsigned long irqflags;

	raw_spin_lock_irqsave(&p->lock, irqflags);
	llcc_start_locked(p, event);
	raw_spin_unlock_irqrestore(&p->lock, irqflags);
}

static void llcc_stop(struct perf_event *event, int flags)
{
	struct sm7675_llcc_pmu *p = to_llcc(event->pmu);
	unsigned long irqflags;

	raw_spin_lock_irqsave(&p->lock, irqflags);
	llcc_stop_locked(p, event);
	raw_spin_unlock_irqrestore(&p->lock, irqflags);
}

static void llcc_read(struct perf_event *event)
{
	struct sm7675_llcc_pmu *p = to_llcc(event->pmu);
	unsigned long flags;

	raw_spin_lock_irqsave(&p->lock, flags);
	llcc_update(p, event, true);
	raw_spin_unlock_irqrestore(&p->lock, flags);
}

static int llcc_add(struct perf_event *event, int flags)
{
	struct sm7675_llcc_pmu *p = to_llcc(event->pmu);
	unsigned long irqflags;
	int ret = 0;

	raw_spin_lock_irqsave(&p->lock, irqflags);
	if (p->removing)
		ret = -ENODEV;
	else if (p->events[event->cpu])
		ret = -EAGAIN;
	else {
		p->events[event->cpu] = event;
		event->hw.idx = p->bank[event->cpu];
		event->hw.state = PERF_HES_STOPPED | PERF_HES_UPTODATE;
		if (flags & PERF_EF_START)
			llcc_start_locked(p, event);
	}
	raw_spin_unlock_irqrestore(&p->lock, irqflags);
	return ret;
}

static void llcc_del(struct perf_event *event, int flags)
{
	struct sm7675_llcc_pmu *p = to_llcc(event->pmu);
	unsigned long irqflags;

	raw_spin_lock_irqsave(&p->lock, irqflags);
	llcc_stop_locked(p, event);
	p->events[event->cpu] = NULL;
	event->hw.idx = -1;
	raw_spin_unlock_irqrestore(&p->lock, irqflags);
}

static int llcc_cpu_pm(struct notifier_block *nb, unsigned long action, void *data)
{
	struct sm7675_llcc_pmu *p = container_of(nb, struct sm7675_llcc_pmu, cpu_pm);
	unsigned int cpu = smp_processor_id();
	struct perf_event *event;
	unsigned long flags;

	if (cpu >= LLCC_CPUS)
		return NOTIFY_DONE;
	raw_spin_lock_irqsave(&p->lock, flags);
	event = p->events[cpu];
	if (action == CPU_PM_ENTER) {
		if (event)
			llcc_update(p, event, false);
		p->idle |= BIT(cpu);
	} else if (action == CPU_PM_EXIT || action == CPU_PM_ENTER_FAILED) {
		p->idle &= ~BIT(cpu);
		if (event && !(event->hw.state & PERF_HES_STOPPED) && !p->suspended && !p->removing) {
			llcc_clear(p, p->bank[cpu]);
			llcc_enable(p, p->bank[cpu], true);
		}
	}
	raw_spin_unlock_irqrestore(&p->lock, flags);
	return NOTIFY_OK;
}

static int llcc_suspend(struct device *dev)
{
	struct sm7675_llcc_pmu *p = dev_get_drvdata(dev);
	unsigned long flags;
	unsigned int cpu;

	raw_spin_lock_irqsave(&p->lock, flags);
	for (cpu = 0; cpu < LLCC_CPUS; cpu++)
		if (p->events[cpu])
			llcc_update(p, p->events[cpu], false);
	p->suspended = true;
	raw_spin_unlock_irqrestore(&p->lock, flags);
	hrtimer_cancel(&p->timer);
	return 0;
}

static int llcc_resume(struct device *dev)
{
	struct sm7675_llcc_pmu *p = dev_get_drvdata(dev);
	unsigned long flags;
	unsigned int cpu;

	raw_spin_lock_irqsave(&p->lock, flags);
	p->suspended = false;
	for (cpu = 0; cpu < LLCC_CPUS; cpu++)
		if (p->events[cpu] && !(p->events[cpu]->hw.state & PERF_HES_STOPPED) && !(p->idle & BIT(cpu))) {
			llcc_clear(p, p->bank[cpu]);
			llcc_enable(p, p->bank[cpu], true);
		}
	if (p->active)
		hrtimer_start(&p->timer, ns_to_ktime(LLCC_POLL_NS), HRTIMER_MODE_REL);
	raw_spin_unlock_irqrestore(&p->lock, flags);
	return 0;
}

static int llcc_cpu_map(struct sm7675_llcc_pmu *p)
{
	struct device_node *node;
	const __be32 *reg;
	unsigned long used = 0;
	unsigned int cpu, bank;
	int cells, bytes;
	u64 id;

	if (num_possible_cpus() != LLCC_CPUS)
		return -EINVAL;
	for_each_possible_cpu(cpu) {
		node = of_get_cpu_node(cpu, NULL);
		if (!node)
			return -EINVAL;
		cells = of_n_addr_cells(node);
		reg = of_get_property(node, "reg", &bytes);
		if (!reg || cells < 1 || cells > 2 || bytes != cells * sizeof(*reg)) {
			of_node_put(node);
			return -EINVAL;
		}
		id = of_read_number(reg, cells);
		of_node_put(node);
		bank = (id >> 8) & 0xff; /* MPIDR affinity level 1. */
		if (cpu >= LLCC_CPUS || bank >= LLCC_CPUS || (id & ~0x700ULL) || (used & BIT(bank)))
			return -EINVAL;
		used |= BIT(bank);
		p->bank[cpu] = bank;
	}
	return 0;
}

static ssize_t llcc_event_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "event=0x1000\n");
}
static struct attribute *llcc_events[] = { PMU_EVENT_ATTR_ID(reads_scaled, llcc_event_show, LLCC_EVENT), NULL };
static const struct attribute_group llcc_events_group = { .name = "events", .attrs = llcc_events };
PMU_FORMAT_ATTR(event, "config:0-15");
static struct attribute *llcc_formats[] = { &format_attr_event.attr, NULL };
static const struct attribute_group llcc_format_group = { .name = "format", .attrs = llcc_formats };
static const struct attribute_group *llcc_groups[] = { &llcc_events_group, &llcc_format_group, NULL };

static int llcc_probe(struct platform_device *pdev)
{
	struct sm7675_llcc_pmu *p;
	struct resource *res;
	int ret;

	res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	if (!res || res->start != 0x24095000 || resource_size(res) != 0x300)
		return -EINVAL;
	p = devm_kzalloc(&pdev->dev, sizeof(*p), GFP_KERNEL);
	if (!p)
		return -ENOMEM;
	ret = llcc_cpu_map(p);
	if (ret)
		return dev_err_probe(&pdev->dev, ret, "unqualified LLCC CPU mapping\n");
	p->base = devm_ioremap_resource(&pdev->dev, res);
	if (IS_ERR(p->base))
		return PTR_ERR(p->base);
	if (readl(p->base + LLCC_CFG) & (GENMASK(7, 0) | GENMASK(23, 16)))
		return dev_err_probe(&pdev->dev, -EBUSY, "LLCC counters already owned\n");
	raw_spin_lock_init(&p->lock);
	hrtimer_setup(&p->timer, llcc_poll, CLOCK_MONOTONIC, HRTIMER_MODE_REL);
	p->cpu_pm.notifier_call = llcc_cpu_pm;
	p->pmu = (struct pmu) {
		.module = THIS_MODULE, .parent = &pdev->dev, .task_ctx_nr = perf_invalid_context,
		.capabilities = PERF_PMU_CAP_NO_EXCLUDE, .attr_groups = llcc_groups,
		.event_init = llcc_event_init, .add = llcc_add, .del = llcc_del,
		.start = llcc_start, .stop = llcc_stop, .read = llcc_read,
	};
	ret = cpu_pm_register_notifier(&p->cpu_pm);
	if (ret)
		return ret;
	ret = perf_pmu_register(&p->pmu, "sm7675_llcc", -1);
	if (ret) {
		cpu_pm_unregister_notifier(&p->cpu_pm);
		return ret;
	}
	platform_set_drvdata(pdev, p);
	return 0;
}

static void llcc_remove(struct platform_device *pdev)
{
	struct sm7675_llcc_pmu *p = platform_get_drvdata(pdev);
	unsigned long flags;

	raw_spin_lock_irqsave(&p->lock, flags);
	p->removing = true;
	raw_spin_unlock_irqrestore(&p->lock, flags);
	perf_pmu_unregister(&p->pmu);
	cpu_pm_unregister_notifier(&p->cpu_pm);
	hrtimer_cancel(&p->timer);
}

static DEFINE_SIMPLE_DEV_PM_OPS(llcc_pm_ops, llcc_suspend, llcc_resume);
static const struct of_device_id llcc_match[] = {
	{ .compatible = "qcom,sm7675-llcc-pmu" }, { }
};
MODULE_DEVICE_TABLE(of, llcc_match);
static struct platform_driver llcc_driver = {
	.probe = llcc_probe, .remove = llcc_remove,
	.driver = { .name = "sm7675-llcc-pmu", .of_match_table = llcc_match, .pm = pm_sleep_ptr(&llcc_pm_ops) },
};
module_platform_driver(llcc_driver);
MODULE_DESCRIPTION("SM7675 LLCC per-CPU read counters");
MODULE_LICENSE("GPL");
