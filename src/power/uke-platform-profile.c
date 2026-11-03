// SPDX-License-Identifier: GPL-2.0-only
/* Uke profile preferences use independent QoS requests; thermal limits still win. */
#include <linux/cpufreq.h>
#include <linux/devfreq.h>
#include <linux/err.h>
#include <linux/init.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/platform_device.h>
#include <linux/platform_profile.h>
#include <linux/pm_opp.h>
#include <linux/pm_qos.h>

#define UKE_POLICIES 3
#define UKE_GPU_MAX_KHZ 950000
/* shortcut: retained 500 MHz preference, revisit after energy/latency qualification. */
#define UKE_GPU_SAVER_KHZ 500000

/* Handoff ABI v1: pending=0, ready=1, permanently unavailable=-1. */
static int probe_status;

static int uke_profile_status_get(char *buffer, const struct kernel_param *parameter)
{
	return scnprintf(buffer, PAGE_SIZE, "%d", READ_ONCE(probe_status));
}

static const struct kernel_param_ops uke_profile_status_ops = {
	.get = uke_profile_status_get,
};
module_param_cb(probe_status, &uke_profile_status_ops, NULL, 0444);

static void uke_profile_publish_state(struct device *dev, int result)
{
	int next = result == -EPROBE_DEFER ? 0 : result ? -1 : 1;
	int previous = READ_ONCE(probe_status);

	WRITE_ONCE(probe_status, next);
	if (dev && previous != next)
		kobject_uevent(&dev->kobj, KOBJ_CHANGE);
}

struct uke_cpu_preference {
	struct cpufreq_policy *policy;
	struct freq_qos_request min_request;
	struct freq_qos_request max_request;
	s32 min_value;
	s32 max_value;
};

struct uke_profile {
	struct device *dev;
	struct device *gpu;
	struct uke_cpu_preference cpu[UKE_POLICIES];
	unsigned int count;
	struct dev_pm_qos_request gpu_request;
	s32 gpu_value;
	enum platform_profile_option selected;
	bool consistent;
};

struct uke_profile_values {
	s32 min[UKE_POLICIES];
	s32 max[UKE_POLICIES];
	s32 gpu;
};

static int uke_profile_admit(void)
{
	const char *driver;

	if (!of_machine_is_compatible("xiaomi,uke") ||
	    !of_machine_is_compatible("qcom,sm7675") || num_possible_cpus() != 8)
		return -ENODEV;
	driver = cpufreq_get_current_driver();
	if (!driver)
		return -EPROBE_DEFER;
	return strcmp(driver, "qcom-cpufreq-hw") ? -ENODEV : 0;
}

static int uke_cpu_request(struct freq_qos_request *request, s32 *saved, s32 value)
{
	int ret = freq_qos_update_request(request, value);

	if (ret >= 0)
		*saved = value;
	return ret < 0 ? ret : 0;
}

static int uke_gpu_request(struct uke_profile *profile, s32 value)
{
	int ret = dev_pm_qos_update_request(&profile->gpu_request, value);

	if (ret >= 0)
		profile->gpu_value = value;
	return ret < 0 ? ret : 0;
}

static int uke_cpu_limits(struct uke_cpu_preference *cpu, s32 min, s32 max)
{
	int ret;

	/* Drop our floor before changing the ceiling, including during rollback. */
	ret = uke_cpu_request(&cpu->min_request, &cpu->min_value, 0);
	if (ret)
		return ret;
	ret = uke_cpu_request(&cpu->max_request, &cpu->max_value, max);
	if (ret)
		return ret;
	return uke_cpu_request(&cpu->min_request, &cpu->min_value, min);
}

static int uke_profile_transaction(struct uke_profile *profile,
				   const struct uke_profile_values *next)
{
	struct uke_profile_values previous;
	bool consistent = profile->consistent;
	int ret, rollback = 0;
	unsigned int i;

	previous.gpu = profile->gpu_value;
	for (i = 0; i < UKE_POLICIES; i++) {
		previous.min[i] = profile->cpu[i].min_value;
		previous.max[i] = profile->cpu[i].max_value;
	}
	ret = uke_gpu_request(profile, next->gpu);
	if (!ret)
		for (i = 0; i < UKE_POLICIES; i++) {
			ret = uke_cpu_limits(&profile->cpu[i], next->min[i], next->max[i]);
			if (ret)
				break;
		}
	if (!ret) {
		profile->consistent = true;
		return 0;
	}
	for (i = 0; i < UKE_POLICIES; i++)
		if (uke_cpu_limits(&profile->cpu[i], previous.min[i], previous.max[i]))
			rollback = -EIO;
	if (uke_gpu_request(profile, previous.gpu))
		rollback = -EIO;
	profile->consistent = consistent && !rollback;
	if (rollback)
		dev_err(profile->dev, "Profile preference restoration incomplete\n");
	return rollback ? rollback : ret;
}

static bool uke_governors_match(struct uke_profile *profile)
{
	unsigned int i;
	bool match;

	for (i = 0; i < UKE_POLICIES; i++) {
		struct cpufreq_policy *policy = profile->cpu[i].policy;

		down_read(&policy->rwsem);
		match = policy->governor && !strcmp(policy->governor->name, "schedutil");
		up_read(&policy->rwsem);
		if (!match)
			return false;
	}
	return true;
}

static int uke_profile_choices(void *data, unsigned long *choices)
{
	__set_bit(PLATFORM_PROFILE_LOW_POWER, choices);
	__set_bit(PLATFORM_PROFILE_BALANCED, choices);
	__set_bit(PLATFORM_PROFILE_PERFORMANCE, choices);
	return 0;
}

static int uke_profile_get(struct device *dev, enum platform_profile_option *choice)
{
	struct uke_profile *profile = dev_get_drvdata(dev);

	*choice = profile->consistent && uke_governors_match(profile) ?
		 profile->selected : PLATFORM_PROFILE_CUSTOM;
	return 0;
}

static int uke_profile_set(struct device *dev, enum platform_profile_option choice)
{
	struct uke_profile *profile = dev_get_drvdata(dev);
	struct uke_profile_values next;
	unsigned int i;
	int ret;

	if (choice != PLATFORM_PROFILE_LOW_POWER &&
	    choice != PLATFORM_PROFILE_BALANCED && choice != PLATFORM_PROFILE_PERFORMANCE)
		return -EOPNOTSUPP;
	if (!uke_governors_match(profile))
		return -EBUSY;
	next.gpu = choice == PLATFORM_PROFILE_LOW_POWER ? UKE_GPU_SAVER_KHZ : UKE_GPU_MAX_KHZ;
	if (dev_pm_qos_read_value(profile->gpu, DEV_PM_QOS_MIN_FREQUENCY) > next.gpu)
		return -EBUSY;
	for (i = 0; i < UKE_POLICIES; i++) {
		next.min[i] = choice == PLATFORM_PROFILE_PERFORMANCE ?
			profile->cpu[i].policy->cpuinfo.max_freq : FREQ_QOS_MIN_DEFAULT_VALUE;
		next.max[i] = choice == PLATFORM_PROFILE_LOW_POWER ?
			profile->cpu[i].policy->cpuinfo.min_freq : FREQ_QOS_MAX_DEFAULT_VALUE;
	}
	ret = uke_profile_transaction(profile, &next);
	if (!ret)
		profile->selected = choice;
	return ret;
}

static const struct platform_profile_ops uke_profile_ops = {
	.probe = uke_profile_choices,
	.profile_get = uke_profile_get,
	.profile_set = uke_profile_set,
};

static void uke_profile_release(void *data)
{
	struct uke_profile *profile = data;
	unsigned int i;

	if (dev_pm_qos_request_active(&profile->gpu_request))
		dev_pm_qos_remove_request(&profile->gpu_request);
	for (i = 0; i < profile->count; i++) {
		struct uke_cpu_preference *cpu = &profile->cpu[i];

		if (freq_qos_request_active(&cpu->min_request))
			freq_qos_remove_request(&cpu->min_request);
		if (freq_qos_request_active(&cpu->max_request))
			freq_qos_remove_request(&cpu->max_request);
		cpufreq_cpu_put(cpu->policy);
	}
	put_device(profile->gpu);
}

static int uke_profile_probe_ready(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev, *handler;
	struct platform_device *gpu;
	struct device_node *node, *duplicate;
	struct dev_pm_opp *opp;
	struct devfreq *devfreq;
	struct uke_profile *profile;
	struct cpufreq_policy *policy;
	cpumask_t seen;
	unsigned long frequency = ULONG_MAX;
	unsigned int cpu;
	int ret;

	ret = uke_profile_admit();
	if (ret)
		return ret;
	profile = devm_kzalloc(dev, sizeof(*profile), GFP_KERNEL);
	if (!profile)
		return -ENOMEM;
	profile->dev = dev;
	profile->selected = PLATFORM_PROFILE_BALANCED;
	profile->consistent = true;
	ret = devm_add_action_or_reset(dev, uke_profile_release, profile);
	if (ret)
		return ret;
	cpumask_clear(&seen);
	for_each_possible_cpu(cpu) {
		struct uke_cpu_preference *preference;

		if (cpumask_test_cpu(cpu, &seen))
			continue;
		policy = cpufreq_cpu_get(cpu);
		if (!policy)
			return -EPROBE_DEFER;
		if (profile->count == UKE_POLICIES || !policy->cpuinfo.min_freq ||
		    policy->cpuinfo.max_freq < policy->cpuinfo.min_freq ||
		    policy->cpuinfo.max_freq > INT_MAX) {
			cpufreq_cpu_put(policy);
			return -ENODEV;
		}
		preference = &profile->cpu[profile->count++];
		preference->policy = policy;
		cpumask_or(&seen, &seen, policy->related_cpus);
		preference->max_value = FREQ_QOS_MAX_DEFAULT_VALUE;
		ret = freq_qos_add_request(&policy->constraints, &preference->min_request,
					   FREQ_QOS_MIN, FREQ_QOS_MIN_DEFAULT_VALUE);
		if (ret < 0)
			return ret;
		ret = freq_qos_add_request(&policy->constraints, &preference->max_request,
					   FREQ_QOS_MAX, FREQ_QOS_MAX_DEFAULT_VALUE);
		if (ret < 0)
			return ret;
	}
	if (profile->count != UKE_POLICIES)
		return -ENODEV;
	node = of_find_compatible_node(NULL, NULL, "qcom,adreno-43030b00");
	if (!node)
		return -EPROBE_DEFER;
	duplicate = of_find_compatible_node(of_node_get(node), NULL, "qcom,adreno-43030b00");
	if (duplicate) {
		of_node_put(duplicate);
		of_node_put(node);
		return -ENODEV;
	}
	gpu = of_find_device_by_node(node);
	if (!gpu) {
		of_node_put(node);
		return -EPROBE_DEFER;
	}
	profile->gpu = &gpu->dev;
	if (!device_link_add(dev, profile->gpu, DL_FLAG_AUTOREMOVE_CONSUMER)) {
		of_node_put(node);
		return -ENOMEM;
	}
	if (!device_is_bound(profile->gpu)) {
		of_node_put(node);
		return -EPROBE_DEFER;
	}
	devfreq = devfreq_get_devfreq_by_node(node);
	of_node_put(node);
	if (IS_ERR(devfreq)) {
		ret = PTR_ERR(devfreq);
		return ret == -ENODEV ? -EPROBE_DEFER : ret;
	}
	opp = dev_pm_opp_find_freq_floor(profile->gpu, &frequency);
	if (IS_ERR(opp))
		return PTR_ERR(opp);
	dev_pm_opp_put(opp);
	if (frequency != (unsigned long)UKE_GPU_MAX_KHZ * 1000)
		return -ENODEV;
	opp = dev_pm_opp_find_freq_exact(profile->gpu,
					 (unsigned long)UKE_GPU_SAVER_KHZ * 1000, true);
	if (IS_ERR(opp))
		return PTR_ERR(opp);
	dev_pm_opp_put(opp);
	profile->gpu_value = UKE_GPU_MAX_KHZ;
	if (dev_pm_qos_read_value(profile->gpu, DEV_PM_QOS_MIN_FREQUENCY) > profile->gpu_value)
		return -EBUSY;
	ret = dev_pm_qos_add_request(profile->gpu, &profile->gpu_request,
				     DEV_PM_QOS_MAX_FREQUENCY, profile->gpu_value);
	if (ret < 0)
		return ret;
	handler = devm_platform_profile_register(dev, "uke-qos", profile, &uke_profile_ops);
	return PTR_ERR_OR_ZERO(handler);
}

static int uke_profile_probe(struct platform_device *pdev)
{
	int ret = uke_profile_probe_ready(pdev);

	uke_profile_publish_state(&pdev->dev, ret);
	return ret ? dev_err_probe(&pdev->dev, ret, "Uke profile provider unavailable\n") : 0;
}

static void uke_profile_remove(struct platform_device *pdev)
{
	uke_profile_publish_state(&pdev->dev, -EPROBE_DEFER);
}

static struct platform_driver uke_profile_driver = {
	.driver.name = "uke-platform-profile",
	.probe = uke_profile_probe,
	.remove = uke_profile_remove,
};

static int __init uke_profile_init(void)
{
	struct platform_device *device;
	int ret;

	if (!of_machine_is_compatible("xiaomi,uke") ||
	    !of_machine_is_compatible("qcom,sm7675"))
		return 0;
	ret = platform_driver_register(&uke_profile_driver);
	if (ret) {
		uke_profile_publish_state(NULL, ret);
		return ret;
	}
	device = platform_device_register_simple("uke-platform-profile", PLATFORM_DEVID_NONE,
						 NULL, 0);
	if (IS_ERR(device)) {
		uke_profile_publish_state(NULL, PTR_ERR(device));
		platform_driver_unregister(&uke_profile_driver);
	}
	return PTR_ERR_OR_ZERO(device);
}
late_initcall(uke_profile_init);

MODULE_DESCRIPTION("Uke CPU and GPU platform-profile QoS preferences");
MODULE_VERSION("1");
MODULE_LICENSE("GPL");
