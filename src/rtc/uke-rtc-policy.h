/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef UKE_RTC_POLICY_H
#define UKE_RTC_POLICY_H
#include <linux/of.h>
#include <linux/types.h>

static inline bool uke_rtc_machine(void)
{
	return of_machine_is_compatible("xiaomi,uke") &&
	       of_machine_is_compatible("qcom,sm7675");
}

static inline bool uke_rtc_qseecom_approved(u32 version)
{
	/* Version observed through the non-mutating SCM query on Uke. */
	return uke_rtc_machine() && version == 0x01402000;
}
#endif
