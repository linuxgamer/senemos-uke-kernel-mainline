# Kernel source integration — 17 October 2026

**18 October update:** the current producer uses signed Linux 7.2.10 and integer
module releases. COPR 11164946 supplies the matched Image, modules, DTBs and
source-built Android boot container for `7.2.10-4`; guarded DNF delivery,
backup/readback and normal persistent boot pass on POCO Pad X1. The .4054 and
.4056 images/modules remain verified rollback material. The native profile now
admits the exact OEM root/sensor contexts and PMIC/CPU thermal integration with
separate physical evidence. The original integration decisions below remain
dated history; see the [current report](../README.md) for later scope and limits.

COPR 11165033 subsequently delivers `7.2.10-5`, adding the tested SMP2P
input-history guard. Signed delivery, boot-B readback and bounded physical
interrupt checks pass. Normal KDE reboot cycles follow an initial forced power
cycle; full shutdown remains unresolved. Original Fedora Plasma Login Manager
starts the current Wayland session.

Environment: Fedora Rawhide development host and the pinned kernel SDK. This
record describes repository ancestry and source selection. It is not a tablet
hardware acceptance report.

The mainline source producer uses Linux 7.2.9, the reviewed native O82 profile,
a unique numeric Senemos module release and the normal mainline package names.
The original main-branch history, dated engineering reports, revision 1.39
host checks and MiCode donor catalogue are retained. The separate native SCM
entry forwards to the same source producer; it no longer creates another
kernel package name. EL2 remains a separate target.

| Earlier branch | Revision | Disposition |
|---|---|---|
| `main` | `7b2d221` | Genuine content/history merge. Retain the donor catalogue and host fixes; preserve the newer mainline source specification. |
| `docs/readme-report-20261013` | `a54aae1` | Historical report retained in ancestry; the later dated main-branch report supersedes the initial draft. |
| `fix/uke-backlight-transitions` | `59abe78` | Retain as an inactive candidate. Its 32 timed fade steps are not the current exact OEM curve; no additional fade timing is enabled. |
| `fix/uke-sensor-fastrpc` | `6d3ebe5` | Retain as an inactive candidate. Its two additional SMMU context-bank admissions need separate source and device qualification. No extra DMA permissions are enabled. |
| `feature/dnf-stock-abl-updates-20261015` | `4eb69e5` | Retain the public dracut/boot producer in history. Its old framebuffer config and early-module inventory are not enabled by the current source package. |
| `fix/uke-spi-provider`, `fix/uke-suspend-diagnostics`, `fix/uke-touch-suppliers` | `22ceedc`, `b89ce9c`, `922d1b4` | Already ancestors of the native source line; no duplicate source changes. |
| `work/native-copr-source-20261017`, `work/native-copr-refresh-20261017` | `f504460`, `1cf6fdf` | The earlier source gate is superseded by the single mainline producer. No separate native package is required. |
| `experiment/adreno732`, `experiment/adreno732-7.2.10` | `2172b8e`, `df1ba2c` | Already present in earlier source ancestry. This integration does not activate the 7.2.10 profile or import another experimental configuration. |
| `experiment/el2-kvm` | `a13a1b9` | Excluded from this integration. Current firmware entry and the mainline profile remain EL1. |

Inactive candidates are preserved through their merged parent commits rather
than copied into the active patch queue. For example,
`git show 4eb69e5:src/boot/build-payload.sh` retrieves the historical public boot
producer. This preserves attributable source without silently enabling an
untested driver, memory permission or boot path.

The complete native profile passed independent SRPM preparation and eight
actual-source host contracts. COPR build 11163806 completed the consolidated
mainline tuple. The separate local `.4054` boot bundle passed package checks,
slot-B readback, normal startup and nine measured transitions through all seven
rates without panel reset. Direct tests found no visible blanking or touch loss.
That local result does not qualify the different COPR binary tuple for boot.
The raw COPR Image must not replace a validated Android boot container. Existing
boot bundles, fallback kernels and published artifacts remain available until
a source-built boot producer has passed its own recoverable tablet test.

## 18 October: combined sensor release 8

COPR 11165188 builds source a831167 as 7.2.10-8 with all 49 base patches and
the separately reviewed, default-off AVR experiment. Signatures, complete module
inventory, Image/container identity and source identity pass. Guarded DNF
delivery preserves Android A, previous images/modules and read-only persist.
Normal KDE reboot starts original Plasma Login Manager and the sensor stack.
All 27 PMIC measurements are readable through IIO/hwmon/KDE; the charger
channel reads 31.29–31.41 °C with USB power; without USB power its near-zero
ADC input produces the OEM-clamped 0 °C. Independent raw/result calculation
checks pass, while absolute calibration remains unqualified. Physical lid and rear-fold
switch transitions pass. These results do not accept automatic cover blanking,
closed-cover startup, real heat protection or physical VRR. The standard VRR
CRTC property attachment is still missing and belongs to the separate test
continuation.
