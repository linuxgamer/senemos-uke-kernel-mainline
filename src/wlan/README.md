# ath11k country-status diagnostics

4 November 2026. The running 1500 kernel reports two firmware country-setting
refusals without their reason. A working TR regulatory domain does not explain
those refusals. Pinned Linux `79a907609d53d5cd645b42c11550d295d43abf99`
also logs the initial status before converting the received status in both
legacy and extended channel-list parsers.

The patch assigns status before logging and extends the existing refusal
warning with the converted status name/value, country, PHY and event kind.
It preserves `-EINVAL`, all rule processing, requests, fallback, retries,
country selection, radio state and firmware. Unknown firmware values retain
the existing generic-failure mapping. It does not claim to fix the refusal or
display/input stalls; accurate reason reporting precedes that investigation.

Primary references are the exact
[Uke WLAN tree](https://github.com/MiCode/vendor_qcom_opensource_wlan/tree/2825b01e22ac3e16345c12e6c85549188e2e765e),
[OnePlus SM7675 failure handling](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm7675/blob/1138e00fee63582a0cc6a53af3286621786827b7/vendor/qcom/opensource/wlan/qca-wifi-host-cmn/umac/regulatory/core/src/reg_build_chan_list.c),
[Linux WMI parsing](https://github.com/gregkh/linux/blob/79a907609d53d5cd645b42c11550d295d43abf99/drivers/net/wireless/ath/ath11k/wmi.c)
and [Linux regulatory handling](https://github.com/gregkh/linux/blob/79a907609d53d5cd645b42c11550d295d43abf99/drivers/net/wireless/ath/ath11k/reg.c).
The OEM/shared-SoC status enum and failure handling are comparison evidence;
their regulatory fallback policy is not transplanted. Original Linux files
retain their BSD-3-Clause-Clear notices.

COPR fixtures import the real enum/conversion/string helpers, both complete
status diagnostic blocks and the original refusal branch. Independent old
legacy/extended/warning assertions must fail; original converted values and
return behavior must pass. Corrected cases cover both events, zero/stale
initial states, all six known codes, unknown codes and two PHY identities,
with GCC/Clang normal and fail-fast sanitizer runs. They model logging only;
full TLV parsing, firmware and rule processing are outside the fixture.
Complete native WMI/regulatory objects and the linked ath11k module are
separate package gates. No network/device API is used by the fixtures.

The producer retains the qualified 2700 source/boot cohort, effective config
and all original package checks. Native execution, signed artifact review,
delivery and matching-kernel observation are pending. No local compilation,
radio reset, scan, country override or firmware change is required to prepare
this candidate.
