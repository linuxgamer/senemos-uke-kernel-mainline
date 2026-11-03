# Uke charging protocols — 18 October 2026

Environment: development-host source inspection/editing only. No test, compiler,
package, tablet read/write or protocol negotiation was performed in this source
task. The VRR coordinator owns actual compilation and staged device acceptance.

## Manufacturer declarations and protocol ownership

The original [POCO Pad X1 FAQ, Battery Q5](https://www.mi.com/ph/support/faq/details/KA-628084/)
explicitly lists tablet receiver QC2.0/QC3.0/QC3+, PD2.0/PD3.0 and MI FC2.0.
Battery Q8 separately describes its supplied charger. These are manufacturer
claims, not certification, Linux functionality or negotiated-session evidence.
The same receiver Q5 is present in the
[Indonesian FAQ](https://www.mi.co.id/id/support/faq/details/KA-628209/).
PPS, QC4/4+ and UFCS are excluded there; no EPR/AVS support is established.
A PD3.0 claim is not a PPS claim. Do not copy a POCO F5 phone's battery, voltage
or advertised protocol list into the tablet or the F5 charger.

The two regional FAQ Ports Q3 answers conflict on reverse wired charging:
Philippines says yes, Indonesia says no. Preserve this document conflict;
exact variant/OEM source/physical evidence must resolve the actual source role.
No reverse-power control is added here.

The OEM DT uses PMIC GLINK `PMIC_RTR_ADSP_APPS` and protection domain
`tms/servreg`, `msm/adsp/charger_pd`, with distinct battery, UCSI and altmode
children. It does not establish an AP-owned standalone QC pulse engine.
Negotiation remains in the reviewed firmware/UCSI owner. Do not add D+/D−
pulsing, a second TCPM engine, raw VBUS requests or proprietary auth bypass.

## Exact source comparison

| Source | Pin and files | Observation |
|---|---|---|
| Uke OEM kernel | `5712080a4b0c0b1a879e6d145c601c649ddaddfd`, `drivers/power/supply/qti_battery_charger.c`, `drivers/usb/typec/ucsi/ucsi_glink.c` | Distinct USB6/adapter7/XM spaces; vendor HVDCP enums and firmware UVDM/authentication interface. |
| Uke OEM DT | `94c84aeb9e517dbde546fc732033c184094c8e57`, `qcom/cliffs.dtsi`, `qcom/uke-sm8635.dtsi` | Firmware charger domain, UCSI and Uke battery/thermal strings. These strings are not portable validated Linux numerical limits. |
| Same-SoC OnePlus | `fc892483f1d61f245924681eb5abd563564d9cba`, same charger C file | Also maps standard USB_TYPE to adapter7; vendor current/protocol policies cannot be transferred to Uke. |
| Shared-protocol Peridot | `2ed9eadbecae21ef51134e556951e7305ba65f88`, `qcom_battmgr.c` | Standard USB getter uses wire6. Inheritance is not exact Uke firmware ABI proof. |
| Local upstream snapshot | `4056b3c9d3c92ea45955641dbafeb9b960e146ef`, `qcom_battmgr.c`, UCSI core/psy and Type-C ABI | USB6 legacy map, standard PD capabilities/reporting, no exact Uke QC/MI session backend. This is a pinned comparison, not remote HEAD. |
| Project input | `f429992feb638e7dffc0142ecb77c6b1a86fc16e` plus charging0067 and USB owner's successor queue | Preserve accepted legacy SDP budget and existing request IDs pending controlled ABI comparison. |

Kernel files retain GPL-2.0-only and their Linux Foundation/Qualcomm Innovation
Center/Linaro/Qualcomm Technologies attribution as applicable. No donor scripts,
foreign limits or firmware were executed/copied as control implementation.
The firmware component's source lock admits no blobs; private OEM OS3.0.304.0
ADSP candidate files are not proof of active firmware identity, protocol tables
or redistribution permission. No firmware protocol source or complete public
MI FC2.0 authentication specification was established by this audit.

## ABI limits and source changes

OEM `usb_prop_map` maps `POWER_SUPPLY_PROP_USB_TYPE` to `USB_ADAP_TYPE=7`.
`USB_TYPE=6` is distinct. OEM `real_type_show()` uses PSY_TYPE_XM and
XM_PROP_REAL_TYPE, not either interchangeable USB getter. HVDCP0x80,
HVDCP_3=0x81, HVDCP_3P5=0x82, USB_FLOAT=0x83 and HVDCP_3_CLASSB=0x84 are vendor
codes. Their names alone do not establish QC2/QC3/QC3+ wire sessions. In
particular, do not rename HVDCP_3P5 to QC3+ without exact firmware evidence.
OEM BrickID9 also differs from the selected kernel's enum11 after AVS additions.

Patch0072 retains the existing wire6 request and bounds only the stable legacy
standard0..8 range; ambiguous/vendor9+ becomes Unknown, with raw family/id,
epochs and receive time preserved at read-only `uke_usb_source_state`. It does
not substitute adapter7, convert vendor values to DCP/QC, add a GET, expose a
raw command or infer a negotiated version. It also rejects nonboolean USB_ONLINE
replies. Other boards retain their existing behavior. The sysfs standard helper
warns/returns EINVAL for unlisted enum values; no array-OOB or observed-device
failure is claimed. Source fixtures add malformed/ambiguous/raw preservation
cases, unexecuted here.

Patch0071 clarifies EXPERT development compilation versus runtime admission;
config defaults stay n. Patch0073 renames the charge guard's `current` temporary
because Linux defines it as `get_current()`. The coordinator found that actual
AArch64 translation failure; the earlier extracted fixtures missed the macro.
The new actual-guard fixture defines the Linux macro and covers age, generation,
signed-current and request failures. The coordinator reports that focused73
fixes OFF/ON translation and the guard fixture, but its temporary70+73 prepared
source is not a coherent packaged tuple. Freeze/integrate71/72/73 before package
claims. No test was executed in this source task.

Companion native `uke-charge-control protocols` is cache-only metadata, without
firmware RPC/service activation. Exact protocol/revision/PDO/RDO/measured power
remain null. It separates the manufacturer list from runtime qualification and
reported normalized legacy USB class. A recent cache is not authenticated ABI
or negotiated-protocol evidence. Control profiles additionally require reviewed
`protocol_property_abi`, `source_contract` and `cable_contract` proof hashes.
The shipped profile remains unqualified; no protocol or power gets enabled.

## Per-protocol remaining capability

| Requested protocol | Existing source path | Evidence still required |
|---|---|---|
| QC2.0 | Firmware charger, adapter7/vendor candidates | Exact active result map, negotiated session and measured V/I envelope with a known QC2 source/cable. |
| QC3.0 | Firmware HVDCP_3 candidate | Exact QC3 status/transition/effect and fallback; generic DCP or increased VBUS is insufficient. |
| QC3+ | HVDCP_3P5 name is only a candidate | Direct OEM mapping/firmware session evidence and qualified QC3+ source; do not infer from a QC3-only source. |
| PD2.0 | Firmware UCSI, gated PDO capability path | Actual session revision, accepted source PDO/RDO/PS_RDY, cable and measured input; generic PD label insufficient. |
| PD3.0 | Same firmware UCSI path | Same exact revision/contract evidence; local/partner capability is not negotiated revision. PPS stays excluded. |
| MI FC2.0 | OEM encrypted charging, UVDM session/auth/adapter candidates | Matched firmware ABI, approved OEM adapter/cable, genuine session/auth/limits and fallback. No synthetic verified=true. |

UCSI transport version is not PD revision. Local `cap.pd_revision` is firmware
capability; partner revision is exposed only when the relevant UCSI>=2.1 fields
exist and is also a capability. GET_PDOS requires UCSI_CAP_PDO_DETAILS and obeys
partner-PDO quirks. Cached UCSI psy voltage_now may be a selected fixed-PDO decode,
not measured input voltage, and must not be decoded as fixed for APDO blindly.
Obtain accepted-session and independent measurements through admitted evidence;
missing fields remain unavailable. Standard framework exposure needs no KDE fork.

## Adapters, cables and staged tests

Begin with computer USB and existing C0/C1; establish exact firmware/provider,
pack limits, independent infrastructure WiFi, stable telemetry, rollback and
user-at-cable abort route. A passive metadata report is not GET admission.
Admit a bounded legacy6 vs adapter7 comparison only through a reviewed typed
backend; do not probe XM ordinals. CONFIG_MI_N2N3ANTIBURN conditionally inserts an
XM enum entry, so vendor IDs require the exact compiled configuration and ABI.

Use a known documented QC2 source for QC2, a QC3 source for QC3, and an explicitly
qualified QC3+ source for QC3+. An ordinary QC3 source cannot isolate QC3+.
Use known PD2 and PD3 sources or an analyzer-approved revision constraint with a
qualified C-C cable; record source capabilities, selected contract and actual
message revision. Adapter advertising/e-marker identity alone does not prove
an accepted session. For MI FC2.0 use the exact OEM adapter revision and approved
proprietary cable without bypassing identity/authentication. POCO F5's 67W label
is not a tablet67W target or proof of any individual charger protocol.

The already planned original tablet/F5/RC1001 adapters each need label/model,
port and cable evidence. RC1001 requires C1/C2 separately, then separately
admitted second-port load attach/detach and renegotiation. A borrowed or unknown
cable is not an OEM auth/5A entitlement. Record any analyzer's transparency and
voltage/current/protocol rating before placing it in the path.

For each protocol: source/host admission -> PC USB baseline -> actual firmware
ABI/source/cable/protection admission -> low-power attach/readback/independent
measurement -> actual SOC80 stop/resume and qualified slow/FCC -> ordinary-load
fixed-display window -> separate actual-VRR comparison -> normal detach/fallback/
resume -> report. No artificial overheat, short circuit, auth bypass, deep
cycle or speculative voltage request. If the source cannot isolate a protocol,
mark that protocol NOT_RUN or BLOCKED rather than passing it as fallback.
Return exact producer/integrated pins, package receipts, raw protocol proof,
signed battery and measured input ranges, faults, coverage and next allowed
stage to the charging thread. Hardware qualification and all F5 gates stay open.
