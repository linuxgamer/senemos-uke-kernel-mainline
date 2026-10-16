# Linux 7.2.9 Uke adaptation

These notes record the patch series as it grew. Early source and build results
below do not describe the later, separately tested revision 1.39 installation.

`0035` follows the upstream remoteproc PD-mapper preload proposal and addresses
the exact Uke charger readiness, USB supplier lifetime and power-supply ABI.
The host fixture executes bounded transient retries, terminal failures,
superseding budgets and missing/failed supplier admission through the actual
functions. Battery fixtures cover signed current, mAh-to-uAh conversion,
overflow rejection and unchanged non-Uke variants. Each retry still passes
the existing online/SDP/source-ceiling checks. Neither a late startup service
nor a higher charging voltage/current is added. Repeated physical boot and
charger readiness remain separate acceptance gates.

`0026` supplies the retained LPASS DDR route needed by the actual Uke ADSP
interconnect: LPICX to LPIAON to LPASS aggregate to GEM/LLCC/EBI. Node IDs,
widths, QoS and HLOS LP0 membership come from the pinned Xiaomi Cliffs OEM
source. The unported PCIe edge remains outside this partial provider; LPASS
GEM is not added to SH1. The actual-C graph fixture checks all registered
edges, the DSP DDR path and unchanged QUP/USB/UFS routes. ADSP startup stays
manual; source/build success does not establish DSP, FastRPC or sensor operation.

Patch 14 adapts Cliffs WPSS PAS metadata and mandatory CX/MX ARC proxy
regulators from the pinned Uke OEM kernel/DT sources. Startup remains manual;
the driver requires AOP load-state QMP. It does not admit WLAN DMA, firmware
redistribution or Wi-Fi hardware acceptance. Run the host fault fixture against
the prepared source with `bash tests/wpss-proxy-contract.sh PATH/TO/qcom_q6v5_pas.c`.
Existing 13-patch boot pairs retain their own pinned package/module tuple.

The first seven patches are derived from the public Uke Linux 6.12
port at `32cad9ccd383ff4b37d8a5e7f88a8bfdcc07307e` by
[ztsubaki](https://github.com/ztsubaki/uke-linux), specifically
`patches/uke/0001-uke-platform-and-usb-port.patch`. Preserve each source file's
Qualcomm/Linux copyright and SPDX license. The original OEM source identity is
recorded in the workspace source catalog. Reference clones are never modified
or executed by the build entry point.

The eighth patch adds the dedicated `qcom,sm7675-qmp-ufs-phy` profile from
Xiaomi's `5712080a4b0c0b1a879e6d145c601c649ddaddfd` OEM Cliffs-compatible
PHY driver. It uses the current upstream QMP implementation, preserving the
OEM effective tuning for both lanes, Gear 4/5 and Rate A/B. The UFS board node
remains disabled until its GCC/GDSC, NoC, supplies, reset and SMMU chain has been
ported and validated. The complete eight-patch Linux 7.2.9 build passed Image,
DTB, 1,146 module, RPM/SRPM and AArch64 package lifecycle checks on October 6.
The detailed build record is not included in this checkout.
This establishes buildability, not a working board UFS link.

The target base is Linux `v7.2.9`, commit
`5fce161649b4d779d1b76d9fcd52dc77779774b8`. Reviewable differences from the
6.12 donor include current pointer-linked interconnect nodes, preserving new
upstream clocks and tests, and using the current DWC3 glue/probe API. The
upstream generic eUSB2 PHY/repeater and DWC3 core stay at their current
implementations. The Uke legacy PHY/repeater and fixed WCD939x route remain
separate, rebuilt drivers; Android vendor modules are never included.

`0015` carries the reviewed UFS/GENI supply and SMMU admission into the
package source, adds only the OEM Uke WLAN SMR ID/mask and RF resources,
and requires all three RF supplies before ath11k starts WPSS. Failed
starts unwind the supplies; failed release retains the enable state for
retry. Other AHB boards retain their existing power path. Host fault
fixtures and source compilation do not establish radio operation.

`0016` corrects the bulk RF enable path to preserve the OEM ICNSS forward
rail order. Reverse shutdown stops on failure and retains the enabled
prefix, allowing a later retry without duplicate votes. Fault fixtures
cover each enable/disable position and failed partial cleanup. The 1.7
package is superseded for WLAN startup; it was not physically radio-tested.

`0017` marks the Cliffs GPIO function using the standard Qualcomm GPIO
initializer. The upstream generic predicate requires its GPIO flag to
permit GPIO pinctrl and consumer ownership together. This addresses the
observed GPIO 119 conflict without weakening strict pin ownership.

`0018` keeps the RPMSG service alias when a GLINK channel node supplies
intents without an OF compatible. Both sysfs and uevents now permit normal
QRTR module autoloading; compatible-bearing OF aliases and errors remain
unchanged. `tests/rpmsg-alias-contract.sh` checks the actual functions.

`0019` includes SDAM's data start in its NVMEM provider aperture. Cell
offsets remain register-relative; the existing hardware bounds and write
protections remain intact. `tests/sdam-aperture-contract.sh` checks the
actual size assignment and bounds predicate, including the final byte.

`0020` adds the exact Uke Cliffs ADSP PAS/DTB identity with manual startup,
reusing the fault-checked CX/MX proxy votes and mandatory AOP QMP path.
The pinned OEM PAS descriptor and Uke DT establish its IDs, names and
levels. The shared proxy fixture checks both ADSP and WPSS descriptors.
This does not port CDSP/NSP memory assignment, FastRPC context banks or
sensor services, and firmware delivery remains private and separate.

`0021` ports the Cliffs GPU clock provider from the pinned Uke OEM kernel
`5712080a4b0c0b1a879e6d145c601c649ddaddfd`. Clock IDs, parents, frequency
tables and reset registers remain OEM-derived. Probe preserves firmware
PLLs, gates and voltage references; provider synchronization releases the
proxy vote only after boot-clock handoff succeeds. The existing clock/VDD
helpers handle error cleanup. Run `tests/gpu-clock-handoff-contract.sh`
with the prepared driver and pinned OEM driver to check table identity,
probe failures, deferred providers and retained votes. Native compilation
and these host checks do not establish DRM or accelerated graphics.

`0022` propagates KTZ8866 enable, brightness and initialization I2C errors
instead of reporting success. Failed enable/disable operations retain the
recorded LED state; a failed low-byte write cannot continue to latch the
high byte. Probe also returns initialization and initial-level failures.
`tests/backlight-write-contract.sh` injects faults into the actual functions
and checks boundary levels. This preserves existing upstream setup and does
not bind the OEM dual-controller graph or qualify Uke brightness control.

`0023` supplies exact OEM QUP1 core/configuration/memory NoC paths and
admits only its wrapper/GPI1 streams (0x423/0x436) in the existing translated
DMA profile. The ABL transform validates the second KTZ8866 bus and OEM DMA
route before converting its binding, and disables all other QUP1 serial
engines and I2C children. Adjacent stream IDs remain rejected. Native
objects, the actual NoC graph fixture and malformed-DT tests are host/build
evidence; both backlight drivers and physical level control remain separate.

`0024` admits the exact live Uke ADSP LCX/LMX and GPUCC MXC ARC resources.
The existing command-database ARC path retains OEM levels and error handling;
no neighboring rail or guessed voltage is substituted. The actual supply
fixture admits sixteen exact names and rejects unrelated/extended names.
Physical provider binding and DSP/graphics operation remain separate gates.

`0025` adopts the exact Uke paired KTZ8866 normal-brightness path.
Probe preserves firmware setup without writes; one class controls both
endpoints using the GPL OEM normal curve, checked readback and verified
rollback. Managed peer ownership, malformed graph and I/O fault fixtures
remain mandatory. HBM, suspend policy and physical brightness are unqualified.

`0027` reads the actual Uke OEM GPR domain from its single `reg` cell only
when `qcom,domain` is absent. The original Xiaomi Uke `gpr-lite.c` at
`8eb0eccbc4027ae4a4987e4bced03a4381039714` reads this field; the actual
ADSP node and GPL domain header both identify domain 2. Preserve explicit
mainline properties and the deprecated APR path; reject foreign machines,
malformed cells and any other legacy domain. The actual-function fixture runs
in native RPM `%check`. ADSP stays manual; FastRPC DMA, PDM maps, audio and
sensor operation remain separately gated.

`0028` adds a Uke-only protection-domain map derived from the five service
registries in the pinned Global OS3.0.304.0 modem image. All four ADSP
domains use instance 74; CDSP root uses 76. Only audio advertises `avs/audio`,
and the existing mapper supplies `tms/servreg` for each domain. These match
existing mainline entries exactly. No firmware bytes are published and no
FastRPC memory permission, DSP autostart or sensor result follows from this map.

Patch 29 adds only Uke's exact OEM two-channel CPUCP mailbox transport from
kernel source `5712080a4b0c0b1a879e6d145c601c649ddaddfd`. Its shared transmit
doorbell and two receive domains differ from modern X1E/Nord register layouts.
Machine and resource identity are checked before any register access. Host
fault controls use the actual resource/I/O/ownership functions and run from
the source RPM's native check phase. No vendor SCMI protocol, CPU power/DVFS
or physical mailbox success follows from this source adaptation.

Patch 30 propagates failed NGD DMA setup through both power-up paths and
runtime resume before controller registration. Failed startup keeps its PM
reference, interrupted QMI waits stop startup, and positive PM resume results
remain successful. The source RPM runs fault injection into the actual startup
functions. Duplicate SSR/PDR ownership, DMA teardown and DSP hardware acceptance
remain open; ADSP stays manual and this does not enable audio or sensors.

At this stage the independent DTS was a **source-build candidate**. It was not
a complete hardware port or a physically accepted UEFI boot image. The DTS
contains Uke MPIDRs,
GIC and firmware static reservations. TLMM is described but disabled pending
profile-specific handoff acceptance. Storage, DRM, touchscreen, wireless,
audio, sensors and charging need further Uke development. The future UEFI
loader must supply exact RAM and dynamic reservations; never boot this tree
by assuming the China source evidence matches the installed Global firmware.
RPM scriptlets only update module dependency indexes, not Android partitions
or the default boot entry.

In the recorded build, Fedora's RPM/package-management stack pulled in Python
during toolchain construction. The build environment package inventory records
it; the target RPMs did not contain Python. Kernel compilation and project
automation in that build used Kbuild/C/Bash.

The Uke callback runs outside the mailbox channel lock because SCMI notification
acknowledgment can re-enter transmit. Shutdown synchronizes the IRQ before the
client is released, and legacy IRQ enable follows channel-lock initialization.
The host contract exercises callback lock reentry and shutdown synchronization.

`0031` translates the exact Uke OEM battery GET and reply IDs: the OEM enum
inserts `BATT_CONSTANT_CURRENT` at wire ID 12, shifting temperature through
charge thresholds by one. The exact `xiaomi,uke` root selects this variant;
other platforms and USB properties keep their original protocol. Signed OEM
temperature conversion is retained, and the existing read-only battery
descriptor remains in use. Unsupported battery SET requests are refused.
The host fixture runs the actual request, reply and selection code against
independent OEM IDs, malformed replies and error paths. This patch does not
start ADSP, change firmware charging policy or establish physical charging.

`0032` admits a separate `xiaomi,uke-pmic-glink` endpoint with only the
upstream battery auxiliary client and the OEM ADSP charger service. The stock
ABL overlay retains the disabled OEM GLINK/UCSI/log graph and fixed peripheral
USB route. The actual data-table fixture and transformed-FDT checks enforce
this boundary. ADSP startup, physical charge/current/temperature trends and
Plasma battery reporting need their own device validation.

Patch 0033 sets exact-Uke charge units, rejects unqualified OEM power telemetry
and keeps unsolicited vendor messages from completing requests. The USB input
write is limited to an online SDP source, its advertised current and 500 mA;
DWC3 supplies the configured USB2 budget through the existing kernel worker.
The exact Uke ADSP starts through remoteproc with recovery held off; the stock
boot overlay contains SLIMbus until its DMA/restart path is qualified. Matched
charger firmware must be available before automatic boot. PD/higher currents,
charging voltage, thermal-policy changes and physical acceptance remain gated.

Patch 0034 connects an optional firmware-framebuffer backlight DT link to
standard DRM CRTC enable/disable. The Uke paired driver already handles zero
brightness and rollback; suspend/resume notification is now enabled. The boot
DT binds only the exact Uke primary backlight, and probe waits for its provider.
It preserves the selected brightness and does not change panel bias, LED current
or DSI timings. Physical screen-off and restore acceptance remains separate.
