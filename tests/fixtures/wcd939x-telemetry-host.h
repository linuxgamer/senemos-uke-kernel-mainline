/* SPDX-License-Identifier: GPL-2.0-only */
/* Fake allocation and cached MBHC providers; no target or register access. */
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uint32_t u32;
#define SNDRV_CTL_ELEM_TYPE_BOOLEAN 1
#define SNDRV_CTL_ELEM_TYPE_INTEGER 2
#define SNDRV_CTL_ELEM_IFACE_MIXER 2
#define snd_BUG_ON(condition) (!!(condition))
#define pr_warn(...) fprintf(stderr, __VA_ARGS__)
struct snd_kcontrol;
struct snd_ctl_elem_info {
	int type;
	unsigned int count;
	union { struct { long min, max; } integer; } value;
};
struct snd_ctl_elem_value {
	union { struct { long value[128]; } integer; } value;
};
struct snd_ctl_elem_id {
	unsigned int iface, device, subdevice, index;
	char name[44];
};
typedef int (*info_fn)(struct snd_kcontrol *, struct snd_ctl_elem_info *);
typedef int (*value_fn)(struct snd_kcontrol *, struct snd_ctl_elem_value *);
struct snd_kcontrol_new {
	unsigned int iface, device, subdevice, count, access, index;
	const char *name;
	info_fn info;
	value_fn get, put;
	union { const void *p; } tlv;
	unsigned long private_value;
};
struct snd_kcontrol {
	struct snd_ctl_elem_id id;
	unsigned int access, count;
	info_fn info;
	value_fn get, put;
	union { const void *p; } tlv;
	unsigned long private_value;
	void *private_data;
};
static int snd_ctl_new(struct snd_kcontrol **result, unsigned int count,
		       unsigned int access, void *unused)
{
	assert(!unused && count == 1);
	*result = calloc(1, sizeof(**result));
	if (!*result)
		return -ENOMEM;
	(*result)->count = count;
	(*result)->access = access;
	return 0;
}
static void strscpy(char *destination, const char *source, size_t size)
{
	assert(strlen(source) < size);
	memcpy(destination, source, strlen(source) + 1);
}
struct wcd_mbhc { u32 left, right; int type; };
struct wcd939x_priv { struct wcd_mbhc *wcd_mbhc; };
struct snd_soc_component { void *dev; struct wcd939x_priv *private; };
static unsigned int cached_reads;
static void *snd_kcontrol_chip(struct snd_kcontrol *control)
{
	return control->private_data;
}
static struct wcd939x_priv *snd_soc_component_get_drvdata(struct snd_soc_component *component)
{
	return component->private;
}
static int wcd_mbhc_get_impedance(struct wcd_mbhc *mbhc, u32 *left, u32 *right)
{
	cached_reads++;
	*left = mbhc->left;
	*right = mbhc->right;
	return *left && *right ? 0 : -EINVAL;
}
static int wcd_mbhc_get_hph_type(struct wcd_mbhc *mbhc)
{
	cached_reads++;
	return mbhc->type;
}
static void fixture_debug(void *device, const char *format, ...)
	__attribute__((format(printf, 2, 3)));
static void fixture_debug(void *device, const char *format, ...)
{
	(void)device;
	(void)format;
}
#define dev_dbg(device, ...) fixture_debug(device, __VA_ARGS__)
