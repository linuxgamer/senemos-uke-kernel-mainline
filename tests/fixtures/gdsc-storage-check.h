/* SPDX-License-Identifier: GPL-2.0-only */
/* Additional lifetime scenarios for the complete imported GDSC implementation. */

static void release_managed_storage(void)
{
	for (int i = 0; i < 2; i++) {
		free(allocated[i]);
		allocated[i] = NULL;
	}
}

static void reset_registration(void)
{
	registration_test = true;
	registered = removed = linked = registration_inits = registration_links = 0;
	allocations = allocation_fail_at = init_error = init_fail_at = 0;
	link_fail_at = provider_error = 0;
	assert(!published && !published_data);
	memset(allocated, 0, sizeof(allocated));
}

#ifdef GDSC_STORAGE_BEFORE
static void storage_before(void)
{
	struct device dev = controller();
	struct regmap map = { .dev = &dev, .status = BIT(16) };
	struct gdsc sc = CAMERA_DOMAIN(&dev, &map);
	struct gdsc *scs[] = { &sc };
	struct generic_pm_domain *slots[1] = { NULL };
	struct genpd_onecell_data data = { .domains = slots, .num_domains = 1 };
	struct gdsc_desc desc = { .dev = &dev, .scs = scs, .num = 1,
		.permanent_data = &data };

	reset_registration();
	assert(!gdsc_register(&desc, NULL, &map));
	assert(published && dev.references == 1 && sc.controller_pm_held);
	fputs("Before-control: managed probe cleanup with a retained published provider\n", stderr);
	release_managed_storage();
	/* The old implementation ignores permanent_data and publishes devres. */
	assert(published_data->num_domains == 1);
	assert(published_data->domains[0] == &sc.pd);
}
#else
static void storage_lifetime(void)
{
	unsigned int cases = 0;
	for (int permanent = 0; permanent < 2; permanent++) {
		for (int on = 0; on < 2; on++) {
			for (int failure = 0; failure < 7; failure++) {
				struct device dev = controller();
				struct regmap map = { .dev = &dev, .status = on ? BIT(16) : BIT(15) };
				struct gdsc domains[3] = {
					CAMERA_DOMAIN(&dev, &map), CAMERA_DOMAIN(&dev, &map),
					CAMERA_DOMAIN(&dev, &map),
				};
				struct gdsc *scs[] = { &domains[0], NULL, &domains[1], &domains[2], NULL };
				struct generic_pm_domain *slots[5] = { NULL };
				struct genpd_onecell_data data = { .domains = slots, .num_domains = 5 };
				struct gdsc_desc desc = { .dev = &dev, .scs = scs, .num = 5,
					.permanent_data = permanent ? &data : NULL };
				int expected = failure == 0 ? 0 : failure <= 3 ? -ENOMEM :
					failure <= 5 ? -EIO : -EEXIST;
				int held;

				reset_registration();
				domains[1].parent = &domains[0].pd;
				domains[2].parent = &domains[1].pd;
				init_fail_at = failure <= 3 ? failure : 0;
				link_fail_at = failure >= 4 && failure <= 5 ? failure - 3 : 0;
				provider_error = failure == 6 ? -EEXIST : 0;
				assert(gdsc_register(&desc, NULL, &map) == expected);
				assert(allocations == (permanent ? 0 : 2));
				held = on ? (init_fail_at ? init_fail_at : 3) : (init_fail_at ? 1 : 0);
				assert(dev.references == held && dev.puts == dev.gets - held);
				if (!failure) {
					assert(published && registered == 3 && linked == 2);
					if (permanent) {
						assert(published_data == &data);
						/* Simulate a later clock/reset probe error and devres cleanup. */
						release_managed_storage();
					}
					assert(published_data->num_domains == 5);
					for (int i = 0; i < 5; i++)
						assert(published_data->domains[i] == (scs[i] ? &scs[i]->pd : NULL));
					gdsc_unregister(&desc);
				} else {
					assert(!published && !registered && !linked);
					if (permanent)
						for (int i = 0; i < 5; i++) assert(slots[i] == NULL);
					if (held) {
						int reads = map.reads, writes = map.writes;
						assert(gdsc_register(&desc, NULL, &map) == -EBUSY);
						assert(dev.references == held && map.reads == reads && map.writes == writes);
					}
				}
				assert(!published && !registered && !linked && !published_data);
				assert(dev.references == held); /* Metadata unwind must not drop boot/uncertain power. */
				/* Explicit verified OFF is a model cleanup, not a proposed failure recovery. */
				for (int i = 0; i < 3; i++)
					if (domains[i].controller_pm_held) assert(!gdsc_disable(&domains[i].pd));
				assert(!dev.references && dev.puts == dev.gets);
				release_managed_storage();
				cases++;
			}
		}
	}
	registration_test = false;
	printf("GDSC: %u managed/permanent sparse lifetime cases, boot ON/OFF and all init/link/provider failures passed\n", cases);
}

static void storage_refusals(void)
{
	for (int failure = 0; failure < 11; failure++) {
		struct device dev = controller();
		struct regmap map = { .dev = &dev, .status = BIT(15) };
		struct gdsc sc = CAMERA_DOMAIN(&dev, &map);
		struct gdsc legacy = { .flags = POLL_CFG_GDSCR, .pwrsts = PWRSTS_OFF_ON };
		struct gdsc *scs[] = { &sc, NULL };
		struct generic_pm_domain *slots[2] = { NULL };
		struct genpd_onecell_data data = { .domains = slots, .num_domains = 2 };
		struct dev_pm_domain_list parents = { 0 };
		struct gdsc_desc desc = { .dev = &dev, .scs = scs, .num = 2, .permanent_data = &data };
		int expected = -EINVAL;

		reset_registration();
		switch (failure) {
		case 0: desc.num = data.num_domains = 0; break;
		case 1: data.domains = NULL; break;
		case 2: data.num_domains = 1; break;
		case 3: data.num_domains = 3; break;
		case 4: desc.pd_list = &parents; break;
		case 5: dev.pm_domain = &sc.pd.domain; break;
		case 6: slots[0] = &sc.pd; expected = -EBUSY; break;
		case 7: slots[1] = &sc.pd; expected = -EBUSY; break;
		case 8: scs[0] = &legacy; break;
		case 9: sc.supply = "managed-is-not-permanent"; break;
		case 10: sc.needs_icc = true; break;
		}
		assert(gdsc_register(&desc, NULL, &map) == expected);
		assert(!allocations && !registered && !linked && !published);
		assert(!map.reads && !map.writes && !dev.gets && !dev.references);
	}
	registration_test = false;
	puts("GDSC: 11 malformed/permanent-storage contracts rejected before allocation or MMIO");
}
#endif
