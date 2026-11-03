// SPDX-License-Identifier: GPL-2.0-only
/*
 * Native Uke LLCC/L3 memory-latency policy. Standard perf and ICC ownership;
 * no Android scheduler hooks, raw clock writes or CPUCP SET commands.
 * Sampling algorithm and DT maps: MiCode Uke 5712080a, dcvs/memlat.c.
 * Copyright (c) 2020-2021, The Linux Foundation. All rights reserved.
 * Copyright (c) 2022-2023 Qualcomm Innovation Center, Inc. All rights reserved.
 */
#include <linux/cpu.h>
#include <linux/cpuhotplug.h>
#include <linux/interconnect.h>
#include <linux/ktime.h>
#include <linux/math64.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/perf_event.h>
#include <linux/platform_device.h>
#include <linux/pm.h>
#include <linux/sched.h>
#include <linux/workqueue.h>
#include "uke-memlat-policy.h"

#define UKE_MEMLAT_MONITORS 7
#define UKE_MEMLAT_SAMPLE_MS 8

struct uke_memlat_cpu {
	struct perf_event *event[UKE_MEMLAT_EVENTS];
	struct uke_memlat_count previous[UKE_MEMLAT_EVENTS];
	u64 timestamp;
};

struct uke_memlat_monitor {
	struct uke_memlat_row map[UKE_MEMLAT_ROWS];
	cpumask_t cpus;
	unsigned int rows, group;
	bool compute;
};

struct uke_memlat {
	struct device *dev;
	struct mutex lock;
	struct delayed_work work;
	struct workqueue_struct *queue;
	struct hlist_node hp_node;
	struct icc_path *path[2];
	struct uke_memlat_cpu cpu[UKE_MEMLAT_CPUS];
	struct uke_memlat_monitor monitor[UKE_MEMLAT_MONITORS];
	unsigned int monitors;
	u32 vote[2];
	u32 l3_requested_khz, l3_ceiling_khz;
	u64 samples, rejected, vote_errors;
	u64 l3_range_rejections, l3_limited_votes;
	int hp_state;
	bool suspended;
};

static void uke_memlat_release_cpu(struct uke_memlat_cpu *cpu)
{
	unsigned int i;

	for (i = 0; i < UKE_MEMLAT_EVENTS; i++)
		if (cpu->event[i]) {
			perf_event_release_kernel(cpu->event[i]);
			cpu->event[i] = NULL;
		}
	cpu->timestamp = 0;
}

static int uke_memlat_online(unsigned int id, struct hlist_node *node)
{
	static const u32 events[] = { 0x08, 0x11, 0x37, 0x17 };
	struct uke_memlat *p = hlist_entry(node, struct uke_memlat, hp_node);
	struct uke_memlat_cpu *cpu = &p->cpu[id];
	struct perf_event_attr attr = {
		.type = PERF_TYPE_RAW, .size = sizeof(attr), .pinned = 1,
	};
	unsigned int i;
	int ret;

	mutex_lock(&p->lock);
	attr.disabled = p->suspended;
	for (i = 0; i < UKE_MEMLAT_EVENTS; i++) {
		attr.config = events[i];
		cpu->event[i] = perf_event_create_kernel_counter(&attr, id, NULL, NULL, NULL);
		if (IS_ERR(cpu->event[i])) {
			ret = PTR_ERR(cpu->event[i]);
			cpu->event[i] = NULL;
			uke_memlat_release_cpu(cpu);
			p->rejected++;
			dev_warn_ratelimited(p->dev, "CPU%u perf counters unavailable: %d\n", id, ret);
			break;
		}
	}
	mutex_unlock(&p->lock);
	/* A policy consumer must never veto CPU hotplug when a PMU is occupied. */
	return 0;
}

static int uke_memlat_offline(unsigned int id, struct hlist_node *node)
{
	struct uke_memlat *p = hlist_entry(node, struct uke_memlat, hp_node);

	mutex_lock(&p->lock);
	uke_memlat_release_cpu(&p->cpu[id]);
	mutex_unlock(&p->lock);
	return 0;
}

static u32 uke_memlat_lower_l3(struct uke_memlat *p, u32 upper)
{
	u32 next = 0;
	unsigned int m, row;

	/* Only consider distinct positive points in the validated OEM L3 maps. */
	for (m = 0; m < p->monitors; m++) {
		const struct uke_memlat_monitor *mon = &p->monitor[m];

		if (mon->group != 1)
			continue;
		for (row = 0; row < mon->rows; row++) {
			u32 khz = mon->map[row].memory_khz;

			if (khz < upper && khz > next)
				next = khz;
		}
	}
	return next;
}

static int uke_memlat_commit(struct uke_memlat *p, const u32 vote[2])
{
	static const u32 width[] = { 16, 32 };
	int ret, first = 0;
	unsigned int i;

	for (i = 0; i < 2; i++) {
		u32 target = vote[i];
		bool limited = false;

		if (i == 1) {
			p->l3_requested_khz = target;
			if (p->l3_ceiling_khz && target > p->l3_ceiling_khz) {
				target = p->l3_ceiling_khz;
				limited = true;
			}
		}
		if (p->vote[i] == target) {
			if (limited)
				p->l3_limited_votes++;
			continue;
		}
		ret = icc_set_bw(p->path[i], 0, target * width[i]);
		if (i == 1 && target && ret == -ERANGE) {
			u32 next;

			p->l3_range_rejections++;
			while ((next = uke_memlat_lower_l3(p, target))) {
				target = next;
				ret = icc_set_bw(p->path[i], 0, target * width[i]);
				if (!ret) {
					/* A mapped, admitted request; not measured hardware frequency. */
					p->l3_ceiling_khz = target;
					limited = true;
					break;
				}
				if (ret != -ERANGE)
					break;
				p->l3_range_rejections++;
			}
		}
		if (ret) {
			p->vote_errors++;
			if (!first)
				first = ret;
			dev_warn_ratelimited(p->dev, "Memory path %u vote failed: %d\n", i, ret);
		} else {
			p->vote[i] = target;
			if (limited)
				p->l3_limited_votes++;
		}
	}
	return first;
}

static void uke_memlat_sample(struct work_struct *work)
{
	struct uke_memlat *p = container_of(to_delayed_work(work), struct uke_memlat, work);
	u64 delta[UKE_MEMLAT_CPUS][UKE_MEMLAT_EVENTS] = { };
	u64 elapsed[UKE_MEMLAT_CPUS] = { };
	u32 vote[2] = { };
	cpumask_t valid;
	unsigned int id, i, m;
	bool complete = true;

	cpumask_clear(&valid);
	/* Match the hotplug callback lock order; no perf read races a release. */
	cpus_read_lock();
	mutex_lock(&p->lock);
	if (p->suspended)
		goto unlock;
	for_each_online_cpu(id) {
		struct uke_memlat_cpu *cpu = &p->cpu[id];
		u64 now = ktime_get_ns();
		bool accepted = cpu->timestamp != 0;

		/* perf reads may send an IPI. Do not wake an idle CPU to sample it. */
		if (idle_cpu(id)) {
			cpu->timestamp = 0;
			continue;
		}
		if (!cpu->event[UKE_MEMLAT_EVENTS - 1]) {
			complete = false;
			continue;
		}
		elapsed[id] = now - cpu->timestamp;
		for (i = 0; i < UKE_MEMLAT_EVENTS; i++) {
			struct uke_memlat_count count;

			count.value = perf_event_read_value(cpu->event[i], &count.enabled, &count.running);
			if (!uke_memlat_delta(&count, &cpu->previous[i], &delta[id][i]))
				accepted = false;
			cpu->previous[i] = count;
		}
		cpu->timestamp = now;
		if (accepted)
			cpumask_set_cpu(id, &valid);
		else
			p->rejected++;
	}
	if (complete)
		for (m = 0; m < p->monitors; m++) {
			const struct uke_memlat_monitor *mon = &p->monitor[m];

			for_each_cpu_and(id, &mon->cpus, &valid)
				vote[mon->group] = max(vote[mon->group],
					uke_memlat_vote(mon->map, mon->rows, mon->compute,
						delta[id][0], delta[id][1], delta[id][2 + mon->group], elapsed[id]));
		}
	uke_memlat_commit(p, vote);
	p->samples++;
unlock:
	if (!p->suspended)
		queue_delayed_work(p->queue, &p->work, msecs_to_jiffies(UKE_MEMLAT_SAMPLE_MS));
	mutex_unlock(&p->lock);
	cpus_read_unlock();
}

static int uke_memlat_parse_monitor(struct uke_memlat *p, struct device_node *node, unsigned int group)
{
	static const char *const allowed[] = {
		"compatible", "name", "phandle", "linux,phandle", "status",
		"qcom,sampling-enabled", "qcom,compute-mon", "qcom,cpulist", "qcom,cpufreq-memfreq-tbl"
	};
	struct uke_memlat_monitor *mon;
	struct device_node *cpu;
	struct property *property;
	u32 cells[2 * UKE_MEMLAT_ROWS];
	int count, i, id;
	unsigned int a;

	if (p->monitors == UKE_MEMLAT_MONITORS ||
	    !of_device_is_compatible(node, "qcom,memlat-mon") ||
	    !of_property_read_bool(node, "qcom,sampling-enabled") ||
	    of_property_read_bool(node, "qcom,cpucp-enabled") ||
	    of_property_read_bool(node, "qcom,threadlat-enabled"))
		return -EINVAL;
	for_each_property_of_node(node, property) {
		for (a = 0; a < ARRAY_SIZE(allowed); a++)
			if (!strcmp(property->name, allowed[a]))
				break;
		if (a == ARRAY_SIZE(allowed))
			return -EINVAL;
	}
	mon = &p->monitor[p->monitors];
	mon->group = group;
	mon->compute = of_property_read_bool(node, "qcom,compute-mon");
	count = of_count_phandle_with_args(node, "qcom,cpulist", NULL);
	if (count < 1 || count > UKE_MEMLAT_CPUS)
		return -EINVAL;
	for (i = 0; i < count; i++) {
		cpu = of_parse_phandle(node, "qcom,cpulist", i);
		if (!cpu)
			return -EINVAL;
		id = of_cpu_node_to_id(cpu);
		of_node_put(cpu);
		if (id < 0 || id >= UKE_MEMLAT_CPUS || cpumask_test_cpu(id, &mon->cpus))
			return -EINVAL;
		cpumask_set_cpu(id, &mon->cpus);
	}
	count = of_property_count_u32_elems(node, "qcom,cpufreq-memfreq-tbl");
	if (count < 2 || count > ARRAY_SIZE(cells) || count % 2 ||
	    of_property_read_u32_array(node, "qcom,cpufreq-memfreq-tbl", cells, count))
		return -EINVAL;
	mon->rows = count / 2;
	for (i = 0; i < mon->rows; i++) {
		mon->map[i].cpu_khz = cells[2 * i];
		mon->map[i].memory_khz = cells[2 * i + 1];
	}
	if (!uke_memlat_map_valid(mon->map, mon->rows, group ? 1804800 : 1066000))
		return -EINVAL;
	p->monitors++;
	return 0;
}

static int uke_memlat_parse(struct uke_memlat *p)
{
	static const char *const names[] = { "llcc", "l3" };
	static const u32 miss[] = { 0x37, 0x17 };
	struct device_node *group, *node;
	u32 event;
	unsigned int i, before;
	int ret;

	for (i = 0; i < 2; i++) {
		group = of_get_child_by_name(p->dev->of_node, names[i]);
		if (!group)
			return -EINVAL;
		if (!of_device_is_available(group) || !of_device_is_compatible(group, "qcom,memlat-grp") ||
		    of_property_read_u32(group, "qcom,miss-ev", &event) || event != miss[i]) {
			of_node_put(group);
			return -EINVAL;
		}
		before = p->monitors;
		for_each_available_child_of_node(group, node) {
			ret = uke_memlat_parse_monitor(p, node, i);
			if (ret) {
				of_node_put(node);
				of_node_put(group);
				return ret;
			}
		}
		of_node_put(group);
		if (p->monitors - before != (i ? 4 : 3))
			return -EINVAL;
	}
	return 0;
}

static ssize_t sampling_show(struct device *dev, struct device_attribute *attr, char *buffer)
{
	struct uke_memlat *p = dev_get_drvdata(dev);
	ssize_t bytes;

	mutex_lock(&p->lock);
	bytes = sysfs_emit(buffer, "samples=%llu rejected=%llu vote_errors=%llu llcc_khz=%u l3_khz=%u suspended=%u l3_requested_khz=%u l3_ceiling_khz=%u l3_range_rejections=%llu l3_limited_votes=%llu\n",
			   p->samples, p->rejected, p->vote_errors, p->vote[0], p->vote[1], p->suspended,
			   p->l3_requested_khz, p->l3_ceiling_khz,
			   p->l3_range_rejections, p->l3_limited_votes);
	mutex_unlock(&p->lock);
	return bytes;
}
static DEVICE_ATTR_RO(sampling);
static struct attribute *uke_memlat_attrs[] = { &dev_attr_sampling.attr, NULL };
ATTRIBUTE_GROUPS(uke_memlat);

static void uke_memlat_stop(struct uke_memlat *p)
{
	u32 zero[2] = { };

	mutex_lock(&p->lock);
	p->suspended = true;
	mutex_unlock(&p->lock);
	cancel_delayed_work_sync(&p->work);
	cpuhp_state_remove_instance(p->hp_state, &p->hp_node);
	cpuhp_remove_multi_state(p->hp_state);
	uke_memlat_commit(p, zero);
	destroy_workqueue(p->queue);
}

static int uke_memlat_probe(struct platform_device *pdev)
{
	struct uke_memlat *p;
	unsigned int i;
	int ret;

	if (!of_machine_is_compatible("xiaomi,uke") ||
	    !of_machine_is_compatible("qcom,sm7675") || num_possible_cpus() != UKE_MEMLAT_CPUS)
		return -ENODEV;
	for_each_possible_cpu(i)
		if (i >= UKE_MEMLAT_CPUS)
			return -EINVAL;
	p = devm_kzalloc(&pdev->dev, sizeof(*p), GFP_KERNEL);
	if (!p)
		return -ENOMEM;
	p->dev = &pdev->dev;
	mutex_init(&p->lock);
	ret = uke_memlat_parse(p);
	if (ret)
		return dev_err_probe(p->dev, ret, "Unsupported Uke MEMLAT maps\n");
	for (i = 0; i < 2; i++) {
		p->path[i] = devm_of_icc_get(p->dev, i ? "l3" : "llcc");
		if (IS_ERR(p->path[i]))
			return dev_err_probe(p->dev, PTR_ERR(p->path[i]), "Memory ICC path unavailable\n");
		if (!p->path[i])
			return -ENODEV;
	}
	p->queue = alloc_workqueue("uke-memlat", WQ_FREEZABLE | WQ_UNBOUND, 1);
	if (!p->queue)
		return -ENOMEM;
	INIT_DEFERRABLE_WORK(&p->work, uke_memlat_sample);
	p->hp_state = cpuhp_setup_state_multi(CPUHP_AP_ONLINE_DYN, "soc/uke-memlat:online",
					    uke_memlat_online, uke_memlat_offline);
	if (p->hp_state < 0) {
		destroy_workqueue(p->queue);
		return p->hp_state;
	}
	ret = cpuhp_state_add_instance(p->hp_state, &p->hp_node);
	if (ret) {
		cpuhp_remove_multi_state(p->hp_state);
		destroy_workqueue(p->queue);
		return ret;
	}
	platform_set_drvdata(pdev, p);
	queue_delayed_work(p->queue, &p->work, msecs_to_jiffies(UKE_MEMLAT_SAMPLE_MS));
	dev_info(p->dev, "Native LLCC/L3 MEMLAT: %u monitors, deferrable %u ms sampling\n",
		 p->monitors, UKE_MEMLAT_SAMPLE_MS);
	return 0;
}

static void uke_memlat_remove(struct platform_device *pdev)
{
	uke_memlat_stop(platform_get_drvdata(pdev));
}

static int uke_memlat_suspend(struct device *dev)
{
	struct uke_memlat *p = dev_get_drvdata(dev);
	u32 zero[2] = { };
	unsigned int id, i;
	int ret;

	mutex_lock(&p->lock);
	p->suspended = true;
	mutex_unlock(&p->lock);
	cancel_delayed_work_sync(&p->work);
	cpus_read_lock();
	mutex_lock(&p->lock);
	ret = uke_memlat_commit(p, zero);
	if (!ret) {
		for_each_online_cpu(id)
			for (i = 0; i < UKE_MEMLAT_EVENTS; i++)
				if (p->cpu[id].event[i])
					perf_event_disable(p->cpu[id].event[i]);
	} else {
		p->suspended = false;
	}
	mutex_unlock(&p->lock);
	cpus_read_unlock();
	if (ret)
		queue_delayed_work(p->queue, &p->work, msecs_to_jiffies(UKE_MEMLAT_SAMPLE_MS));
	return ret;
}

static int uke_memlat_resume(struct device *dev)
{
	struct uke_memlat *p = dev_get_drvdata(dev);
	unsigned int id, i;

	cpus_read_lock();
	mutex_lock(&p->lock);
	for_each_online_cpu(id) {
		p->cpu[id].timestamp = 0;
		for (i = 0; i < UKE_MEMLAT_EVENTS; i++)
			if (p->cpu[id].event[i])
				perf_event_enable(p->cpu[id].event[i]);
	}
	p->suspended = false;
	mutex_unlock(&p->lock);
	cpus_read_unlock();
	queue_delayed_work(p->queue, &p->work, msecs_to_jiffies(UKE_MEMLAT_SAMPLE_MS));
	return 0;
}

static DEFINE_SIMPLE_DEV_PM_OPS(uke_memlat_pm_ops, uke_memlat_suspend, uke_memlat_resume);
static const struct of_device_id uke_memlat_match[] = {
	{ .compatible = "xiaomi,uke-memlat" }, { }
};
MODULE_DEVICE_TABLE(of, uke_memlat_match);
static struct platform_driver uke_memlat_driver = {
	.probe = uke_memlat_probe, .remove = uke_memlat_remove,
	.driver = {
		.name = "uke-memlat", .of_match_table = uke_memlat_match,
		.dev_groups = uke_memlat_groups, .pm = pm_sleep_ptr(&uke_memlat_pm_ops),
	},
};
module_platform_driver(uke_memlat_driver);
MODULE_DESCRIPTION("Native Uke LLCC/L3 perf-based memory-latency votes");
MODULE_LICENSE("GPL");
