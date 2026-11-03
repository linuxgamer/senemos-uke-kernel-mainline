/* SPDX-License-Identifier: GPL-2.0-only */
/* Keep CONFIG_CMDLINE_FORCE; admit bounded root, boot-slot and private VRR controls. */
#ifndef UKE_ROOT_SELECTOR_H
#define UKE_ROOT_SELECTOR_H

#ifdef __KERNEL__
#include <linux/elfnote.h>

/* Compiler emits the note; the kernel NOTES linker rule retains it. */
ELFNOTE64("UKE", 0x554b4501,
	  "root-selector-v2;userdata=f2fs,ext4,xfs,btrfs;slot=a,b;vrr-min=0,30");
ELFNOTE64("UKE", 0x554b4502,
	  "boot-reset-v1;watchdog=gunyah;open-timeout=180;runtime-timeout=30");
#endif

static int UKE_INIT uke_cmdline_space(char value)
{
	return value == ' ' || value == '\t' || value == '\r' || value == '\n';
}

/* All validation precedes mutation. No allocation or filesystem discovery. */
static int UKE_INIT uke_select_root(char *cmdline, size_t capacity,
				   const char *handoff, size_t bytes)
{
	static const char prefix[] = "senemos.root=";
	static const char standard[] = "root=PARTLABEL=linux";
	static const char userdata[] = "root=PARTLABEL=userdata";
	static const char fstypes[] = "rootfstype=ext4,f2fs,xfs,btrfs";
	static const char panic[] = "panic=0";
	static const char reset_args[] = " senemos.boot_reset=1 gunyah_wdt.boot_enabled=1 watchdog.open_timeout=180 systemd.watchdog_sec=30";
	size_t pos = 0, length = 0, root = 0, roots = 0;
	size_t fstype = 0, fstype_count = 0, panic_pos = 0, panic_count = 0;
	const char *slot = NULL, *vrr = NULL;
	size_t slot_bytes = 0, vrr_bytes = 0, extra, shrink;
	int selected = 0;
	int boot_reset = 0;

	if (!cmdline || !capacity || bytes > 8192 || (!handoff && bytes))
		return -1;
	if (bytes && (handoff[bytes - 1] || memchr(handoff, 0, bytes - 1)))
		return -1;
	while (bytes && pos < bytes - 1) {
		size_t start, count;

		while (pos < bytes - 1 && uke_cmdline_space(handoff[pos]))
			pos++;
		start = pos;
		while (pos < bytes - 1 && !uke_cmdline_space(handoff[pos]))
			pos++;
		count = pos - start;
		if (count >= sizeof("senemos.boot_reset=") - 1 &&
		    !memcmp(handoff + start, "senemos.boot_reset=", sizeof("senemos.boot_reset=") - 1)) {
			if (boot_reset || count != sizeof("senemos.boot_reset=1") - 1 ||
			    memcmp(handoff + start, "senemos.boot_reset=1", count))
				return -1;
			boot_reset = 1;
			continue;
		}
		if (count >= sizeof("androidboot.slot_suffix=") - 1 &&
		    !memcmp(handoff + start, "androidboot.slot_suffix=",
			    sizeof("androidboot.slot_suffix=") - 1)) {
			if (slot || count != sizeof("androidboot.slot_suffix=_a") - 1 ||
			    (memcmp(handoff + start, "androidboot.slot_suffix=_a", count) &&
			     memcmp(handoff + start, "androidboot.slot_suffix=_b", count)))
				return -1;
			slot = handoff + start;
			slot_bytes = count;
			continue;
		}
		if (count >= sizeof("msm.o82_vrr_test_min_hz=") - 1 &&
		    !memcmp(handoff + start, "msm.o82_vrr_test_min_hz=",
			    sizeof("msm.o82_vrr_test_min_hz=") - 1)) {
			if (vrr ||
			    !((count == sizeof("msm.o82_vrr_test_min_hz=0") - 1 &&
			       !memcmp(handoff + start, "msm.o82_vrr_test_min_hz=0", count)) ||
			      (count == sizeof("msm.o82_vrr_test_min_hz=30") - 1 &&
			       !memcmp(handoff + start, "msm.o82_vrr_test_min_hz=30", count))))
				return -1;
			vrr = handoff + start;
			vrr_bytes = count;
			continue;
		}
		if (count < sizeof(prefix) - 1 ||
		    memcmp(handoff + start, prefix, sizeof(prefix) - 1))
			continue;
		if (selected)
			return -1;
		if (count == sizeof("senemos.root=linux") - 1 &&
		    !memcmp(handoff + start, "senemos.root=linux", count))
			selected = 1;
		else if (count == sizeof("senemos.root=userdata") - 1 &&
			 !memcmp(handoff + start, "senemos.root=userdata", count))
			selected = 2;
		else
			return -1;
	}
	if ((vrr || boot_reset) && selected != 2)
		return -1;
	while (length < capacity && cmdline[length])
		length++;
	if (length == capacity)
		return -1;
	pos = 0;
	while (pos < length) {
		size_t start, count;

		while (pos < length && uke_cmdline_space(cmdline[pos]))
			pos++;
		start = pos;
		while (pos < length && !uke_cmdline_space(cmdline[pos]))
			pos++;
		count = pos - start;
		if ((count >= sizeof("senemos.boot_reset=") - 1 && !memcmp(cmdline + start, "senemos.boot_reset=", sizeof("senemos.boot_reset=") - 1)) ||
		    (count >= sizeof("gunyah_wdt.boot_enabled=") - 1 && !memcmp(cmdline + start, "gunyah_wdt.boot_enabled=", sizeof("gunyah_wdt.boot_enabled=") - 1)) ||
		    (count >= sizeof("watchdog.open_timeout=") - 1 && !memcmp(cmdline + start, "watchdog.open_timeout=", sizeof("watchdog.open_timeout=") - 1)) ||
		    (count >= sizeof("systemd.watchdog_sec=") - 1 && !memcmp(cmdline + start, "systemd.watchdog_sec=", sizeof("systemd.watchdog_sec=") - 1)))
			return -1;
		if (count >= sizeof("rootfstype=") - 1 &&
		    !memcmp(cmdline + start, "rootfstype=", sizeof("rootfstype=") - 1)) {
			if (++fstype_count != 1 || count != sizeof(fstypes) - 1 ||
			    memcmp(cmdline + start, fstypes, count))
				return -1;
			fstype = start;
			continue;
		}
		if (count >= sizeof("panic=") - 1 &&
		    !memcmp(cmdline + start, "panic=", sizeof("panic=") - 1)) {
			if (++panic_count != 1 || count != sizeof(panic) - 1 ||
			    memcmp(cmdline + start, panic, count))
				return -1;
			panic_pos = start;
			continue;
		}
		if ((count >= sizeof("androidboot.slot_suffix=") - 1 &&
		     !memcmp(cmdline + start, "androidboot.slot_suffix=",
			     sizeof("androidboot.slot_suffix=") - 1)) ||
		    (count >= sizeof("msm.o82_vrr_test_min_hz=") - 1 &&
		     !memcmp(cmdline + start, "msm.o82_vrr_test_min_hz=",
			     sizeof("msm.o82_vrr_test_min_hz=") - 1)))
			return -1;
		if (count < 5 || memcmp(cmdline + start, "root=", 5))
			continue;
		if (++roots != 1 || count != sizeof(standard) - 1 ||
		    memcmp(cmdline + start, standard, count))
			return -1;
		root = start;
	}
	if (roots != 1 || fstype_count != 1 || panic_count != 1)
		return -1;
	shrink = selected == 2 ? 0 : sizeof(",f2fs,xfs,btrfs") - 1;
	extra = (selected == 2 ? sizeof(userdata) - sizeof(standard) + 1 : 0) +
		(slot ? 1 + slot_bytes : 0) + (vrr ? 1 + vrr_bytes : 0) + (boot_reset ? sizeof(reset_args) - 1 : 0);
	if (extra >= shrink && capacity - length <= extra - shrink)
		return -1;
	/* Keep the admitted probe list for userdata; legacy Linux remains EXT4. */
	memmove(cmdline + fstype + sizeof(fstypes) - 1 - shrink,
		cmdline + fstype + sizeof(fstypes) - 1,
		length - fstype - (sizeof(fstypes) - 1) + 1);
	length -= shrink;
	if (root > fstype)
		root -= shrink;
	if (panic_pos > fstype)
		panic_pos -= shrink;
	if (selected == 2) {
		memmove(cmdline + root + sizeof(userdata) - 1,
			cmdline + root + sizeof(standard) - 1,
			length - root - (sizeof(standard) - 1) + 1);
		memcpy(cmdline + root, userdata, sizeof(userdata) - 1);
		length += sizeof(userdata) - sizeof(standard);
		if (panic_pos > root)
			panic_pos += sizeof(userdata) - sizeof(standard);
		memmove(cmdline + panic_pos + sizeof(panic),
			cmdline + panic_pos + sizeof(panic) - 1,
			length - panic_pos - (sizeof(panic) - 1) + 1);
		memcpy(cmdline + panic_pos, "panic=10", sizeof("panic=10") - 1);
		length++;
	}
	if (slot) {
		cmdline[length++] = ' ';
		memcpy(cmdline + length, slot, slot_bytes);
		length += slot_bytes;
	}
	if (vrr) {
		cmdline[length++] = ' ';
		memcpy(cmdline + length, vrr, vrr_bytes);
		length += vrr_bytes;
	}
	if (boot_reset) {
		memcpy(cmdline + length, reset_args, sizeof(reset_args) - 1);
		length += sizeof(reset_args) - 1;
	}
	cmdline[length] = 0;
	return selected == 2;
}
#endif
