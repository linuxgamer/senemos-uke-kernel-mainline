# Permanent native CAMCC registration

3 November 2026. This source joins the catalog, voltage callbacks, resource
owner, sensor prerequisites and optional permanent GDSC storage into one
built-in Uke controller. This qualification producer compiles it as unlinked
AArch64 objects only. It does not bind a device, link the driver into Image,
activate DT, install a candidate or qualify physical cameras.

The driver obtains required parents/supplies before publication. Initial
maximum votes protect possible firmware clock rates before runtime PM adds
its MIN votes. Boot-ON PLLs are preserved; unsupported FSM control is refused
because the admitted catalog supplies no independent FSM vote register/mask.
Shared RCG initialization snapshots CFG without parking. Explicit startup
references cover enabled RCGs whose native operations use software enable
counts; PLLs, dividers, RCGs and branches register in parent-first order.

Clock/reset/genpd provider storage has permanent lifetime. Missing suppliers
and other clean preflight failures unwind and can retry. An uncertain or
published failure retains objects, parent handles, voltage and interface
resources and keeps the permanent driver bound with a latched fault. Its
read-only state attribute reports the fault. Provider lookups and reset
operations reject early/faulted state. No user unbind, module unload, dynamic
DT or second controller is admitted. No failed-probe path silently drops live
resources through devres.

The composed sync callback releases CCF boot holds and explicit RCG startup
references before calling the existing genpd sync. Linux 7.3.1 already holds
boot-ON genpds through `stay_on`; no extra proxy device or permanent always-on
domain is needed. Its `dev_set_drv_sync_state()` refuses to overwrite the
existing composed callback. Only after those steps may maximum voltage and
the initial controller reference be released. Errors retain the remaining
state. Branch vote/halt, RCG update/parking and both PLL shutdown postconditions
observe otherwise silent native void-disable failures. Reset writes retain
PM on error and check completion rather than discard regmap results.

The native MMIO/API boundary fixture imports actual registration/handoff
functions and stable framework helpers. It checks cold/boot-ON paths, every
modeled probe error point, lookup gates, reset failures and composed handoff.
It runs ordinarily and with fail-fast ASan/UBSan on COPR. Separate complete
built-in and inspection objects check real kernel types before the full
retained-kernel build, without linking or executing either driver object.
Framework boundaries are modeled; timing, electrical recovery, concurrent
consumers, CRM, CCI/CAMSS, fitted identity and physical capture remain separate.

Provenance: exact Uke OEM DT/camera-kernel, Xiaomi/OnePlus Cliffs CAMCC and
Palawan catalog inputs retain their earlier pins/attribution. Native helper
review uses Greg Kroah-Hartman Linux v7.3.1 `clk-alpha-pll.c`, `clk-branch.c`,
`clk-rcg2.c`, `reset.c`, `drivers/pmdomain/core.c` and `include/linux/device.h`.
The public driver matches `qcom,sm7675-camcc`; the OEM compatible is unchanged
in the actual DT. Native DT must also reorder clock inputs to iface/XO/XO-AO/
sleep, replace legacy ownership and complete firmware/graph admission before
activation. The OEM clock list has a different index order.

The exact OEM catalog also uses CRM-specific PLL/RCG operations for part of
the tree. The Palawan-derived native catalog replaces these with software
operations. Neither matching register offsets nor this object qualification
establishes CRMC ownership or safe bypass. Exact active firmware/controller
mode and the CRM/native relationship must be reconciled before activation;
the new compatible remains absent from the current DT until that work passes.

The direct-programming candidate now requires an exclusive, named `crm` MMIO
resource at the exact Uke base0xadd7000/size0x2000. After the initial voltage
votes and interface/runtime-PM reference, it enables/checks the four exact OEM
always-on transport gates. The guard verifies DRV_AHB at0x13318, then reads
CRM_ENABLE at0xc before CRM-managed PLL/RCG/branch programming or publication.
Only zero admits the direct
path. Any nonzero mode is refused, retaining the controller resources in the
existing bound fault state. Cached read-only `crm_mode` reports that observation
without accessing an unpowered register. The guard never writes CRM or a LUT.
An unexpected pre-PM reference also retains parents/mapping in quarantine.

Exact OEM CRM and CAMCC code, together with the Qualcomm20April2026 upstream
CESTA proposal, establish that enabled CRM owns PLL/RCG/CBC programming through
votes and firmware lookup tables. The proposed SM8750 display driver has a
different CRM descriptor/register layout from Uke's v1 camera block; it is
reference evidence, not a portable replacement. Active Uke CRM still requires
matched vote/IRQ/LUT/voltage ownership and implementation. The disabled-mode
guard alone establishes neither complete firmware handoff nor physical support.
Its actual resource/admission source and native probe ordering are qualified
separately in ordinary/fail-fast sanitizer checks and real kernel object builds.
