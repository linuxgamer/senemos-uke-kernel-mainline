# AHB Wi-Fi removal before firmware registration

18 October 2026. Linux 7.2.10 source and host-test correction for the active Uke
kernel candidate. Physical validation remains pending. This change supplies
no new WLAN firmware, board values, calibration, regulator or stream-ID policy.

The AHB probe can finish before a QMI firmware service appears. The existing
remove callback enters full core teardown in that unregistered state, while
the same file's shutdown callback checks ATH11K_FLAG_REGISTERED first. Patch
0063 uses that existing lifecycle boundary for removal. It drains queued
initialization work before selecting partial cleanup; registered devices keep
their normal full teardown. Existing QMI-failure cleanup is retained.

The reviewed sources are Linux 7.2.10 and current upstream commit
32c52ec87d6245ee2d12ed5dd509e40062939b50,
drivers/net/wireless/ath/ath11k/ahb.c. Exact Uke OEM kernel
5712080a4b0c0b1a879e6d145c601c649ddaddfd and same-SoC Nord 4 kernel
fc892483f1d61f245924681eb5abd563564d9cba retain the older unguarded removal
structure. Their int-return callback and power-down interface differ from the
current void-return Linux callback; no vendor board settings are transferred.

The actual-source callback fixture fails against the original unregistered
path and passes after the change on x86 GCC and AArch64 Clang. It checks
unregistered, registered, QMI-failed and recovery states, including a recovery
timeout. The test executes no hardware or firmware operation. The running
release-18 loss of live control has no captured panic stack and is not assigned
a confirmed root cause by this source result. Automatic suspend also remains
an alternative until device logs can be recovered.

This patch is included only in the 7.2.10 queue, now 63 entries. The separate
7.2.9 queue remains at its integration checkpoint. New package and physical
boot/network, firmware-absent removal and suspend validation are still needed.
Use a bounded sleep inhibitor for unattended live tests and preserve the
accepted boot/module fallback.
