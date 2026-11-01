# Mainline native source profile

1 November 2026, kernel1041 testing-image candidate: combine the exact COPR1020
USB/LMH/power source with default-off O82 CABC and the retained30 Hz AVR floor.
Accepted running1003 remains separate from this uninstalled candidate. Original
KWin controls five logical tiers mapped to four OEM modes; HDR adaptation is
refused. Full remote checks and separate tablet acceptance are required. See
[the source and validation limits](../../docs/O82-ADAPTIVE-BACKLIGHT.md).

1 November 2026, isolated kernel1003 candidate: compose the explicit O82 30 Hz
AVR floor and zero-brightness first-frame fix over the exact installed116 SRPM.
Retain its power/startup fixes, matching family and all122 adaptation patches.
The requested floor is no longer silently raised to90 Hz. Electrical limits
remain unchanged; low-refresh touch, cadence and lifecycle need tablet acceptance.

31 October 2026, unstable kernel106 candidate: preserve release102's four isolated
capture channels and deliver one named four-channel input with the kernel.
Bounded ADC/TX defaults move to DT and apply before capture power-up, including
after ALSA state restore. Per-release ALSA/WirePlumber data coexists with older
kernels, while frozen legacy data permits removing the separate audio RPM.
Singleboot metadata declares automatic activation and requires updater 1.9.0 or newer,
with guarded-automatic, final-transaction and boot-reset capabilities retained.
The updater owns policy and validation for inactive-slot DNF transactions.
Source preparation is complete; COPR and installed kernel106 acceptance remain
pending. The preceding pre-start ADC8/TX24 trial on102 records four clean
channels; it is not kernel106 validation or measured SNR improvement.

31 October 2026, POCO Pad X1, Fedora Rawhide AArch64: release 13 produces
complete nonzero mono recordings from each AMIC1/3/4/5 individually, with the
selected ADC/route active and controls restored. The release 16 source
candidate preserves selected 1/2/4-channel requests at 48 kHz S16_LE and requires
the exact matching contiguous TX decimator mask. Supplies, reset, pins, IRQs
and playback graphs remain. Simultaneous independent capture, desktop policy
and physical aperture positions require separate device validation.

30 October 2026, isolated microphone source candidate: the optional
`microphones` profile retains speaker/DP playback and adds a restricted mono
AMIC1/ADC1/DEC0 capture graph. The default remains `speakers`. DT/topology,
memory-only callbacks and twelve AArch64 audio objects pass focused checks.
No candidate installation, raw capture or four-microphone qualification is
claimed. See [the bring-up record](../../docs/MICROPHONE-BRINGUP-20261030.md)
for source provenance, activation gates and rollback requirements.
30 October 2026, release61 isolated boot-reset candidate: retain the accepted
release54 source baseline and add a bounded Gunyah watchdog handoff. The signed
Image declares a separate reset capability note. Only the exact userdata
`senemos.boot_reset=1` wrapper enables the early watchdog, 180-second kernel
ownership deadline, original systemd's 30-second watchdog and the initramfs
startup deadline. Normal Linux and legacy userdata wrappers retain their policy.
The paired updater 1.9.0 preserves the accepted slot, selects three trial
attempts, and bounds the unaccepted real-root startup. Kernel watchdog sysfs
inspection is enabled without probing or altering board-specific registers.

The upstream Gunyah driver at Linux c03c1a14507dfaf8b856c2608f9ac216021fc222
stops the watchdog at probe. The opt-in patch starts it and transfers its running
state to the original watchdog core; its existing SMCCC ABI and 32-second
hardware maximum are unchanged. Source fixtures exercise the actual probe and
parser. Boot failures before this probe require independently verified firmware
coverage. Hardware reset, bootloader retry exhaustion, both slot directions,+suspend and recovery remain physical qualification gates. This candidate does
not activate or reboot the tablet during source generation or package checking.

30 October 2026, Linux 7.3.0-53 security candidate: enforce matching module
signatures, integrity lockdown, FORTIFY, hardened usercopy, Yama and restricted
kernel logs. COPR verifies final compressed modules with the exported build
certificate and rejects tampered payloads and wrong keys. The generated private
key is removed after the final Image build. This candidate is not activated or
physically qualified; its trust does not establish Secure Boot.

29 October 2026, Linux 7.3.0-50 source candidate: keep FEC error counting
disabled during link training and enable it after verified decoder/FEC startup.
Read back the requested selector before publishing active compression. Every
valid nonzero active count still triggers recovery; no error threshold or
periodic reset is added. The timing fixture also imports the actual component
encoding. Release 49 boots, produces visible independent compressed SMPTE and
tiles patterns, and restores visible plain output without USB removal, but
nonzero receiver counts leave full DSC acceptance open. Release-50 native
delivery and physical qualification remain pending.

29 October 2026, Linux 7.3.0-49 source candidate: restore the matched Uke OEM
DTO force-ACK lifecycle during setup and pixel-clock shutdown. The packet
fixture reproduces the preceding missing ACK state and checks held/released
register values. Real clock-shutdown tests cover power, platform, stream bounds
and duplicate cleanup. AArch64 syntax checks pass; native delivery and tablet
qualification remain pending. Installed release 48 confirms the timing-control
correction and automatic visible fallback, but compressed pixels still fail
with and without VSC metadata. No physical DSC acceptance is claimed.

29 October 2026, Linux 7.3.0-48 source candidate: restore the exact Uke OEM and
same-SoC OnePlus bit-8 timing-control write during external stream setup. The
existing caller restricts this function to SM7675. Read-modify-write retains
other bits for both compressed and plain streams. The real packet fixture
fails on release 47's missing write and passes after correction. This is a
bounded source candidate; the bit's role in the remaining failure is unproved.
Installed release 47 has corrected PPS/padding/data windows, but QHD60 10-bpc,
QHD75 8-bpc and FHD60 10-bpc compressed trials remain black with valid FEC errors.
Automatic visible fallback works without USB removal. No DSC acceptance is claimed.

29 October 2026, Linux 7.3.0-47 source candidate: trigger PPS transmission with
flush bit 0 and clear one-shot bit 2, matching the Uke OEM continuous-PPS
configuration. The preceding implementation sets only bit 2; release-45
register capture confirms that value. A real packet-programming assertion
fails before correction and passes afterward for both initial modes, 8/10 bpc
and preserved unrelated bits. This includes the release-46 data-window fix;
three-byte end-of-line padding also uses arithmetic rounding, since kernel
ALIGN requires a power of two. The corrected fixture reproduces the missing
QHD padding seen in the tablet register dump. Its superseded release-46 COPR
build is canceled before delivery. Physical compression
remains unaccepted until a fresh signed-package and tablet trial.

29 October 2026, Linux 7.3.0-46 source candidate: match the active and display
data windows for compressed DisplayPort, following the exact Uke OEM and
same-SoC OnePlus interface contract. Release-45 register capture shows the
display window programmed and the active window zero while compressed output
is black. The real timing function fails the new assertion before correction
and passes afterward at FHD/QHD/UHD, 8/10 bpc; existing O82 and uncompressed
checks remain. This source correction requires separate physical qualification.

29 October 2026, Linux 7.3.0-45 source candidate: use eight-bit packetizer
transport for DSC, retaining input depth in PPS/MSA. Mark changes in selected
stream bpp or normalized DSC parameters as mode changes so CRTC programming
runs during attached on/off and fallback. Actual-function fixtures reproduce
both preceding omissions and pass after correction. Four translation units
pass AArch64 header syntax checks. Release-42 tablet trials reach decoder
enable but fail FEC and visible-image acceptance; manual display disable/enable
restores uncompressed output without USB removal. Neither source nor package
checks establish physical success. Subsequent release-45 tablet and webcam
trials confirm automatic visible uncompressed recovery without USB removal;
compressed pixels still fail with a valid uncorrected FEC count.

29 October 2026, Linux 7.3.0-44 source candidate: retain a DRM device reference
through attached policy changes and refuse missing, unregistered or replaced
bindings before altering state. Stop policy/health work before component
teardown. Production-function fixtures include an unbind during lock acquisition
and check balanced references. This is source evidence, not a physical hot-unbind
or compressed-image qualification.

28 October 2026, Linux 7.3.0-43 source candidate: apply negotiated link-budget
reduction to SST as well as MST. Recheck atomic admission after a smaller
trained link and keep DSC eligible for that bandwidth retry. Reset the retry
notification only after strict budget progress; receiver faults retain the
compression-failure latch. Host regression covers the formerly missed SST
case. Actual trained-link downshift and compressed output remain separate
physical validation gates.

28 October 2026, Linux 7.3.0-42 source candidate: select DSC automatically only
when uncompressed output cannot preserve the admitted precision/bandwidth.
The attached root policy supports auto/on/off through a full DRM modeset;
failed DSC is latched out until a fresh attachment or explicit policy request.
Read back receiver decoder/FEC enable, monitor lane status and qualified FEC
counters, and request bounded uncompressed recovery on failure. Existing
USB-PD and lane routing are retained. Host source tests do not qualify a
visible compressed image, cable-free recovery or sustained tablet operation.

28 October 2026, Linux7.3.0-41 source candidate: retain Rob Clark's proposed
GEM blocking control and select nonblocking reclamation for the Uke kernel.
Keep inactive eviction, normal swap, reservation ownership, active-buffer
checks and no-progress errors. Report freed pages even when a scanned LRU
becomes empty, as required by the actual MM caller. The actual policy/scan
fixture has32 checks; the old source fails10 and the candidate passes all.
This is source/model validation, not physical acceptance of the new policy.

The runtime control disabling all GEM eviction avoids multi-second stalls in
three loaded panel cycles, but removes normal swapping as well. That control
is restored after measurement. Release41 uses the narrower proposed upstream
mechanism. Restore the preceding THP default: release40's first comparison
improves, but repeated MADVISE trials still stall22.6seconds. Release40/COPR
11219571 is canceled before publication and does not establish a fix.

28 October 2026, canceled Linux7.3.0-40 source trial: default transparent huge pages
to advised mappings instead of all anonymous mappings. A kernel38/Plasma6.8.2
panel-transition trace records21.6-second direct reclaim and22-second display
gaps under the preceding policy. A bounded runtime madvise comparison records
1.151ms maximum direct reclaim and413ms maximum DP presentation gap; repeat
and fresh-boot acceptance remain separate. Retain THP for applications that
request it, all normal allocation errors and the existing swap configuration.
No CMA size, GPU capability, firmware, timeout or board value is changed.

28 October 2026, Linux 7.3.0-39 source candidate: select the bounded VP9 empty
NOSHOW completion correction in both decode orders. Recycle only a valid unused
linear capture buffer; preserve corruption, overflow, ownership, LAST/PSC and
queue submission errors. The preceding source fails eight modeled checks;
the candidate passes35. The fresh release38 baseline has17 failed assertions;
the earlier eight-failure count refers only to the preceding trial comparison.
This selects the complete change against release38,
including the initial handler absent from the earlier incremental patch file.
Signed delivery and current Chrome/session acceptance remain separate gates.

27 October 2026, Linux 7.3.0-28 source candidate: restore reviewed MDT, FastRPC
coherent-buffer and transport-stop safeguards absent from the 7.3 queue. Bound
ELF32 metadata before copying and validate carveout geometry before PAS setup.
Actual-code sanitizer checks reproduce the original failures and pass after the
changes, including read-only retained CDSP/DTB headers. Native CDSP power, PAS,
FastRPC/DMA integration and physical compute acceptance remain open. No firmware
bytes or automatic remoteproc start are added.

27 October 2026, Linux 7.3.0-27 source candidate: apply coordinated-reset
dependencies to the actual Type-C USBSS module. The separate fixed USB2 driver
retains its original dependency scope. Actual Kconfig checks cover the complete
profile and every missing pin/reset/supply dependency. Retain release-26 BWMON
error handling; physical audio, bandwidth voting and boot acceptance remain open.

27 October 2026, Linux 7.3.0-26 source candidate: retain release-25 audio
foundations and preserve the last successful BWMON bandwidth when an OPP vote
fails. Report rate-limited errors; later IRQ requests can retry an unchanged
target. Actual IRQ-thread host fault checks pass. Native BWMON resource/OPP
translation and physical counter, vote, IRQ and lifecycle acceptance remain open.

27 October 2026, Linux 7.3.0-25 source candidate: retain release-24 RNG, ICE
and transactional MCQ, and restore the reviewed VA/TX/RX and coordinated codec
reset foundations. One SM7675 LPASS pin controller supplies the existing speaker
TDM pins and optional reset child. Preserve USBSS routing on failed or absent
audio suppliers; clean partial children before parent power removal. Actual-code
host fixtures, combined-FDT checks and AArch64 objects pass. Physical codec,
SoundWire, jack, analog USB-C playback/capture and boot acceptance remain open.

27 October 2026, Linux 7.3.0-22 source candidate: report the exact Snapdragon
7+ Gen 3 product, LPDDR5X and SKU-specific Focus accessory labels. Preserve
the existing Pad 7/POCO selection; enable the FM19511 tag only for POCO.
Nine firmware-owned SSC descriptions retain explicit model candidates, and
the upstream LIRC transmitter uses the OEM SPI SE1 route. Remove the absent
fingerprint template and reviewed unreferenced panel/input test data.
Host fixtures, focused schemas, pin/provider checks and the NFC ARM64 object
pass. Tablet boot, NFC RF interaction and IR optical acceptance remain open.
See `docs/DT-HARDWARE-20261027.md` in the source repository.

26 October 2026, Linux 7.3.0-17 candidate: move NT36532 contact reporting into
the kernel input driver. The new DT binding supplies CSOT coordinate bounds;
the driver requests shared model firmware directly, checks coordinate mode,
validates complete packets and publishes ten type-B slots. Panel-generation,
IRQ, watchdog, charger and gesture guards remain in the kernel. The V4L2 raw
transport and separately built userspace contact processor are removed from
this kernel payload. Boot integration skips its legacy service for the new
binding and retains dispatch for installed rollback kernels. This is a test
candidate: physical contact geometry, multitouch and lifecycle acceptance must
be recorded after installation; an idle mode readback is not a contact test.

26 October 2026, Linux 7.3.0-16 candidate: add two-stream DP MST using the
upstream v7 implementation and IRQ_HPD v8 bridge contract, adapted to retain
Uke's SST color, DSC/FEC and runtime-PM guards. Uke OEM INTF0/3 map to DP0
streams 0/1. Failed payload allocation, ACT, stream enable and link downshift
release their resources without stopping a surviving stream. Identical IRQ_HPD
routing preserves the retimer; training is bounded by acknowledged C/E or D/F
pin routing. No firmware override or new negotiation owner is introduced.

MST admits RGB8 SDR; HDR, chroma conversion and compressed MST are refused.
The current firmware does not expose standard alternate-mode override, and
the observed JH925 route reports two lanes and MST_CAP=0. Host fault fixtures
and AArch64 MSM compilation pass; native package delivery, a visible second
stream, four-lane negotiation and USB/Ethernet fallback remain unvalidated.
Source attribution: Yongxing Mou and Abhinav Kumar, MST v7 (29 September 2026),
and Dmitry Baryshkov, IRQ_HPD v8 (24 October 2026). See the source links in
`patches/display/0061-uke-dp-mst-and-negotiated-lanes.patch`.

26 October 2026, Linux 7.3.0-15 candidate: clear both latched FEC detection
events after acknowledged FEC_READY and before training. A stale enable event
must not qualify a new compressed link. Status-clear failures abort setup;
default-off policy, disconnected-only changes and the RGB fallback are retained.
Actual receiver-sequence and compressed-TU fixtures cover stale/fresh events,
write failures, 8/10-bpc equivalence and 1440p/4K source timings. Source/host
checks remain separate from native package delivery and visible DSC acceptance.

Release 14 is delivered through signed COPR/DNF and boots with matching modules.
Its connected-policy safeguard is verified; physical compression is still open.

26 October 2026, Linux 7.3.0-14 candidate: opt-in external RGB DSC accepts
8/10-bit input at 8 compressed bits per pixel, one or two source-bounded slices
and compatible receiver capabilities. Policy changes require disconnection.
The driver checks FEC detection and DSC enable responses, uses upstream RC/PPS
helpers and preserves the downstream HDMI TMDS budget. PPS register writes
stop at the 88-byte RGB field boundary before the audio register bank.
Host capability, geometry, failure, parity and atomic-state checks pass.
Compression is off by default; native packaging, visible DSC output, shared
DPU resources and reconnect stability remain unqualified. A 1440p monitor
does not qualify 4K output, and DSC does not increase its HDMI TMDS limit.
No MST, forced Type-C pin assignment or chroma-conversion path is added.

25 October 2026, release-13 delivery: signed COPR 11206321 installs through DNF
and boots with matching modules. One RTC-woken s2idle trial preserves valid
battery properties and synchronized read-only 70/80 charge settings without
USB reconstruction. This supersedes the pending delivery statement below;
gesture entry, keyboard wake and complete display resume remain open.

25 October 2026, Linux 7.3.0-13 candidate: release 12 resumes from a physical
USB mouse wake, but suspending an in-flight battery request permanently latches
the transport's EPIPE guard. Drain its serialized owner before marking the
transport suspended. An inconsistent pending request aborts suspend; genuine
timeout, removal and firmware-generation ambiguity remain blocked. Host tests
execute the actual request, callback and PM functions with a concurrent reply.
Package delivery and battery telemetry across tablet sleep remain untested.
No charge setting, firmware reset or external DSC path is added.

25 October 2026, Linux 7.3.0-12 candidate: release-11 tracing shows normal
touch firmware reaches INIT but cannot finish REK calibration after panel
blanking. The OEM gesture path keeps its initialized firmware. Retain that
known firmware state across transport quiescence, refuse gesture entry when
it is unavailable, and invalidate it on release, fault, watchdog or a
non-gesture suspend. Normal cold startup remains unchanged. The DP RGB
selection also checks the HDMI monitor's advertised TMDS limit independently
of DP bandwidth. Host tests and AArch64 objects pass; native delivery and
physical wake remain open. This does not enable external DSC or FEC.

25 October 2026, Linux 7.3.0-11 candidate history: checked Uke double-tap commands
request panel power retention only after normal-firmware admission and command
readback. A separate input reports checksum-valid double taps as KEY_WAKEUP.
Reset, failed entry, removal and shutdown retain the full quiesce/power-off
path. Wake IRQ ownership is balanced across system sleep. The paired SMEM lid
consumer reports a wake event only for a valid opening; its selected ADSP
parent dispatches nested events during s2idle without an unconditional wake.
Closing and tablet-mode events do not report wake. Deep-suspend wake, physical
gestures, power consumption and accessory wake require tablet validation.
The release-10 graphics, video, AUX and ELD source is preserved. No external
DSC/FEC or Type-C pin override is enabled by these wake changes.

25 October 2026, Linux 7.3.0-5 candidate: the native Cliffs Iris path adds
checked firmware mappings, controller/reset/IRQ ownership and the exact Uke
VIDEOCC/SMMU graph. It retains the published release-4 display, USB and RGB
changes. Firmware availability is checked before codec registration; no OEM
firmware blob is part of this source package. The graph uses the four source
OPPs shared by the exact Uke module and the inspected Cliffs SKU tables.
Source fixtures and AArch64 objects pass. Full kernel/RPM and tablet codec,
power, precision, performance and application acceptance remain open.


25 October 2026, Linux 7.3 source release 4: the kernel owns the Uke RGB LED
through an LED consumer and managed LPG supplier link. Battery capacity comes
from `qcom-battmgr-bat`: below 15%, red breathes for three seconds and stays off
for two; below 5%, red is on for one second and off for two without a fade.
The fixed `/dev/uke-rgb` ABI accepts bounded HEX/brightness, automatic-mode and
ten-second color-wheel requests. A trusted future front-camera stream owner
can request a two-second green breath through `uke_rgb_front_camera_active()`;
no camera pipeline is connected by this revision. Camera indication takes
priority over a test, then battery warnings, manual color and off.

Control 1.12.0 is the confined userspace broker. The kernel refuses competing
brightness, intensity and trigger stores while the consumer is bound. Closing
the exclusive writer restores automatic battery policy. Full suspend and
shutdown request off; resume refreshes capacity. No unreviewed SDAM/PBS hardware
pattern is enabled, so animation during full suspend is not implemented.
The original LPG driver and low PWM ceiling, 8/511, remain unchanged.
Host policy, ioctl lifetime, multicolor ownership and ARM64 header/API syntax
checks pass; this is not a kernel-module/Image/RPM build or tablet result.
Visible color, timing, electrical/thermal behavior, supplier removal and suspend
still require validation with the matched kernel and SELinux-enforcing broker.

25 October 2026, Linux 7.3 source release 2: the guarded Uke torch/RGB profile
and bounded flash-driver cleanup are integrated from the reviewed 7.2.12 work.
Torch-only devices now expose real 5 mA per-channel steps: the retained 20 mA
total ceiling provides native levels 0/1/2 (off/10/20 mA total), used by Control
1.11.0 as 0/50/100%. Flash-capable devices retain their existing scale and
camera API. This revision has no kernel/RPM build or tablet result. No voltage,
current ceiling, strobe or RGB peak-current setting is increased.

Linux 7.2.12 history, 25 October 2026, release 41: the reviewed Uke PMXR2230 graph uses original
upstream flash/LPG drivers. Rear channels 1 and 4 share a 20 mA torch-only
ceiling; flash/strobe is not exposed. RGB and torch register off by default.
The downstream controller nodes remain disabled. The QCOM flash cleanup is
bounded for torch-only children and checked with AddressSanitizer. Actual
light output, electrical measurements and lifecycle acceptance remain open.
The uninstalled release-39 build was canceled after its C++ admission fixture
exposed missing explicit C pointer conversions in the shared test header.
Release 40 stopped during source preparation because the native-display patch
context had not followed the new admission block. Release 41 refreshes that
context and requires complete source preparation before submission.

24 October 2026: release 36 retains RF regulator devres independently of the
manually freed ath11k private allocation. Failed/deferred probe journals from
releases 22, 31 and 34 show the corresponding cleanup fault. The actual helper
passes host address/undefined-sanitizer lifetime and failure fixtures; the
unmodified baseline reproduces use-after-free. Voltage constraints, RF power
order and display/USB policy are unchanged. Package and repeated tablet boot
acceptance remain separate validation gates.

**24 October 2026, release 32 candidate:** Uke DisplayPort gains checked
HDR10/BT.2020 state, full-range RGB VSC and real HDR metadata SDPs. HDR requires
advertised sink metadata/VSC support, 10-bit depth and enough trained bandwidth;
insufficient bandwidth refuses the modeset. Stream failures balance clock,
PHY and PM ownership and report a bad link asynchronously. The read-only
`uke_dp_stream_state` attribute reports sequential cached lane/rate/bpp/capability
observations without AUX, MMIO or PM-resume side effects. The source cache does
not establish a visible HDR image. Original KDE controls remain authoritative.
Current firmware exposes no manual DP alternate-mode override, and the driver
has no MST implementation. No four-lane/MST/USB-fallback acceptance is claimed.

**24 October 2026, release 30 candidate:** `audio-profile=hdmi-only` connects
one stereo 48 kHz/16-bit playback frontend to `DISPLAY_PORT_RX_0` and the native
MSM DP codec. Juo performs the downstream DP-to-HDMI conversion. Only the exact
Uke audio-ion SID pair may acquire a DMA context; frontend registration refuses
an absent or identity domain before PCM construction can map buffers. The
topology uses GC containers and four digital modules. Internal amplifier,
microphone, SoundWire and TDM paths remain disabled. The separate closed
registration profile is retained. Native build, actual DSP/DMA success,
monitor playback and unplug/cover lifecycle validation remain required.

24 October 2026 source candidate: release 25 avoids a GPU recovery/fault-capture
lock cycle observed on POCO Pad X1 with release 22. Optional SMMU fault capture
uses a nonblocking GPU lock so its completion can release a waiting GMU
transaction. Ordinary fault reporting, uncontended capture and existing
recovery remain. The actual-function host fixture fails before the change and
passes afterward. This does not explain the initial GMU timeout or establish
tablet recovery, suspend, graphics performance or endurance. Display, touch
and charging settings are preserved.

The touch source lock advances to existing owner `2b5530f2412a`, which buffers
the CPIO export and reports service readiness after the first valid frame.
Its reviewed archive and retained legacy source RPM remain hash-checked. Contact
processing, calibration, firmware and the kernel transport are unchanged.

24 October 2026 source candidate: release 24 retains the O82 connector range
when fixed modes fall below the opted-in VRR floor. Opted-in requests from
30 through 89 Hz now use the observed 90 Hz trial floor consistently for timing,
DRM metadata and module-parameter readback. Zero still disables the experiment;
fixed modes and the atomic, bonded-host and foreign-hardware checks remain.
This carries the current diagnostic module's higher-floor behavior into the
complete matched kernel package without a separate module loader or boot-note
ABI change. The operator reported reduced Discover movement/resize stutter
with the diagnostic range correction at 90 Hz; remaining stutter, continuous
optical cadence, energy and endurance are unqualified. No permanent effect,
governor, thermal or independent touch-rate change is included.

23 October 2026 source candidate: release 21 retains the enabled boot-derived
early framebuffer and stdout until MSM's existing firmware-aperture takeover.
Its backlight link is removed so simpledrm neither waits for nor blanks the
native panel backlight. The complete splash reservation and native panel
supplies/reset remain preserved. Actual FDT fixtures precede packaging; visible
continuity requires a separate recoverable tablet trial. No physical result is
inherited from the package build. The optional O82 laboratory tool uses the
verified stable platform DRM path so early DRM card numbering cannot select
the GPU by mistake; its experimental display run remains separately gated.

23 October 2026 source candidate: release 20 targets only
`qcom/sm7675-xiaomi-uke.dtb` and the native O82 overlay. The resolved profile
excludes foreign SoC suppliers, panels, fixed Ethernet, SATA, raw flash and
unrelated board controllers. It retains USB peripherals, the four root
filesystems, virtualization, firewall, diagnostics and the existing Uke
hardware/firmware guards. `NR_CPUS=8` follows Uke's eight-core topology.
The Uke DISPCC remains in `dispcc-sm8550.c`; its Kconfig dependency now admits
the existing Cliffs GCC without requiring a foreign GCC. The early module list
contains Uke providers, generic recovery interfaces and their dependencies;
the build rejects a missing dependency before creating the initramfs.
Package and recoverable tablet boot validation remain separate gates.

23 October 2026 source candidate: release 20 targets only
`qcom/sm7675-xiaomi-uke.dtb` and the native O82 overlay. The resolved profile
excludes foreign SoC suppliers, panels, fixed Ethernet, SATA, raw flash and
unrelated board controllers. It retains USB peripherals, the four root
filesystems, virtualization, firewall, diagnostics and the existing Uke
hardware/firmware guards. `NR_CPUS=8` follows Uke's eight-core topology.
The Uke DISPCC remains in `dispcc-sm8550.c`; its Kconfig dependency now admits
the existing Cliffs GCC without requiring a foreign GCC. The early module list
contains Uke providers, generic recovery interfaces and their dependencies;
the build rejects a missing dependency before creating the initramfs.
Package and recoverable tablet boot validation remain separate gates.

21 October 2026 upstream refresh: Linux 7.2.12-1 carries the release-17
98-patch Uke profile, disabled audio and guarded updater contract. The original
7.2.11 queue and device records remain historical evidence. Source preparation
and COPR results do not establish boot or physical acceptance of 7.2.12.

21 October 2026 source follow-up: release 17 retains release 16's nftables,
root-filesystem and inactive audio policy. It adds the retained root-selector
capability, a lasting guarded-updater dependency, an independent OEM SDP adapter
check and the current per-CPU USB workqueue API. The active adaptation has 98
patches. The [USB admission record](../../docs/USB-SDP-ADAPTER-2026-10-21.md)
keeps zero-current and electrical suspend unqualified. No automatic charging
profile, boot activation or physical acceptance is introduced by this source.

17 October 2026. The native O82 profile is part of
`senemos-uke-linux-kernel-mainline`; there is no separate native kernel package.
The root `make srpm` and `.copr/Makefile` use one specification and source
producer. `packaging/native/Makefile` remains a compatibility SCM entry pointing
to the same producer. EL2 work remains separate.

The current source RPM contains signed Linux 7.2.11 and 80 ordered Uke patches,
the ABL adaptation, native DPU/DSI patches, the exact O82-42 seven-mode overlay,
configuration, contract checks, source commit and asset hashes. Integer releases
use separate module paths: `7.2.10-29`, `7.2.10-30`, then `7.2.11-1` after the
upstream source update. Install-only packages do not obsolete
or overwrite a previous kernel build.

Release 2 restores the source-built boot tuple: Image, matching modules,
independent DTB/native overlay, and a kernel-only Android v4 boot container.
The dracut base is generated on the AArch64 build worker from original Fedora
packages. The 376 early modules follow the native56 inventory with PAS excluded;
PAS starts after the real root supplies OEM firmware. The native updater writes
only when its local configuration explicitly enables automatic updates. It keeps
the previous full image and validates readback. Release 4 passes signed COPR
artifact checks and normal persistent tablet boot; the earlier native56 boot
is separate evidence.

Commit `4eb69e5`, published as `feature/dnf-stock-abl-updates-20261015`, contains
a dracut and guarded boot-container producer. Release 2 integrates its source
with the current O82, SSC, Bluetooth and bounded CDC startup configuration.
Private initramfs files, firmware, credentials and
per-device calibration are not source inputs here.

Upstream Linux's MSM register generator
`drivers/gpu/drm/msm/registers/gen_header.py` has SHA-256
`81763fc03ea0ebf254ab7427af2113dc0c7c0d80dceab61232b6e371463d1f90`.
It converts upstream XML into register headers and is an unavoidable host-only
Python build dependency. No project Python or Python payload is supplied to the
tablet; package installation checks reject Python files and runtimes.

## PMIC and CPU thermal candidate, 18 October 2026

Release 3 introduces the source change; release 4 admits the exact OEM PMIC ADC graph through upstream ADC5 Gen3,
IIO, iio-hwmon and generic-adc-thermal. It exports 23 supported channels and
connects ten board thermistors to their existing thermal zones. Four private
charger scalers remain unexported; GLINK battery telemetry remains separate.
Processed voltage uses the IIO millivolt ABI, including the two divided-voltage
channels previously classified as temperature by the upstream table.

Thirteen OEM emergency cooling maps are connected to the three standard
cpufreq cooling devices. The OEM 110 degree junction triggers and respective
8/10 degree hysteresis remain unchanged. Vendor CPU pause is replaced by
frequency cooling; the complete OEM skin and BCL policy is not implemented.
Candidate 37 adds the proposed Qualcomm BCL hwmon driver and the matching
standard emergency attributes. The retained Uke PM7550BA node is admitted
only with its exact parent, register/IRQ layout and measured revision metadata.
PMXR2230 remains separate. Probe preserves firmware enable state and thresholds;
it does not implement the vendor current/voltage thermal proxies or MEMLAT.
Unavailable ADC samples return `ENODATA`, and alarm work/wake cleanup is serialized.
Host fault fixtures and AArch64 object compilation are separate from a matched
candidate boot, measurement accuracy, physical alarms and policy acceptance.
Candidate 38 also rejects empty PM7550BA current samples with `ENODATA`,
following the OEM invalid-zero contract. Release 37 booted and exposed voltage,
thresholds and three IRQs; its zero current samples did not establish zero load.
The exact release 4 COPR bundle boots normally. Its 23 IIO channels, ten board
thermal consumers and thirteen CPU cooling bindings are present. The full
installation has 67 readable hwmon temperature inputs and 51 thermal zones,
including overlapping measurements. Software-emulated thermal events lower
all three CPU policy limits and the GPU cap; all emulation is cleared afterward.
Actual heat protection and sustained workloads remain unqualified.

Release 5 adds a tested SMP2P history guard: ordinary entry notifications cannot
replay asserted ADSP ready/handover edges. Both genuine restart transitions
still reset input history. COPR 11165033 passes signed artifact checks; DNF
delivery and boot-B readback pass. Bounded tablet traces confirm the corrected
edge handling. Subsequent normal KDE reboots reach the installed system; the
first release-5 boot follows a forced power cycle. Full shutdown remains open.

Release 6 adds the four previously excluded OEM charger/battery ADC scalers,
with signed current, standard mA/mC units and a distinct battery thermistor
binding. The graph retains all 27 OEM channels. Full-code arithmetic sweeps,
battery monotonicity and malformed-resource refusal fixtures pass on the host.
COPR and tablet acceptance remain separate gates.

Release 7 maps the exact OEM lid/table SMP2P entries to standard EV_SW input
devices. The kernel reads remote open/closed line state and ignores missing or
conflicting initial reports. It neither acquires SSC-owned GPIOs nor introduces
polling or a startup service. Host state/refusal tests and the exact OEM graph
pass; normal module startup and physical Linux switch events remain separate
tablet gates.

Release 8 combines these sensor changes with the separately reviewed bounded
O82 video AVR experiment. Host checks pass against the combined source.
The read-only module parameter defaults to zero; no connector capability or
qualified VRR range is advertised. Physical activation tests use the separate
[AVR procedure](../../docs/O82-VRR-EXPERIMENT.md) after package delivery.

Release 2 compiles the full kernel but fails the early-PAS guard because its
module inventory includes PAS. Release 3 is cancelled before repeating that
known packaging fault. Release 4 removes PAS from the early inventory and
keeps the fail-closed check. No failed bundle is installed on the tablet.

Combined release 8 passes signed COPR 11165188 delivery, boot-B readback and
normal KDE reboot. The Hall module and both input devices appear automatically; physical lid and rear
fold/unfold events pass through standard evdev, and logind tracks the lid.
All 27 PMIC channels appear in IIO, hwmon and the original KDE backend with
standard units. Internal charger temperature reads 31.29–31.41 °C with USB
power. Without USB power its near-zero input produces the OEM-clamped 0 °C,
which is not a measured ambient temperature. Independent conversion checks
pass; absolute calibration remains unqualified. Battery temperature
and signed current feedback values are readable. Cover display policy, closed
cover boot, calibration accuracy and real heat protection remain unqualified.
The included AVR code defaults off and lacks the standard CRTC property
attachment; activation testing remains a separate continuation.

The 18 October 2026 Bluetooth candidate translates the exact selected Uke UART
wake interrupt to the falling edge requested by its OEM driver. The upstream
wake-IRQ helper retains the DT trigger, so keeping the OEM level cell causes
repeated runtime-PM wakeups. Host FDT fixtures preserve the other IRQ cells and
reject foreign graphs. Standard Bluetooth LE and modular BNEP are enabled for
the original desktop services. Matched package, idle-IRQ and Bluetooth device
validation remain separate from these source checks.

A separate 18 October source correction removes only the exact unused legacy
VA scalar qcom,is-used-swr-gpio=1. Upstream OF interprets its suffix as a GPIO
specifier and incorrectly resolves value 1 to the interrupt controller. The
actual FDT helper preserves native compatibles and other values. This does
not enable audio or alter the SoundWire pinctrl reference; tablet warning
validation remains pending.

## Full Type-C source candidate, 18 October 2026

The versioned `usb-profile` now selects `typec-v1` for the next combined native
build. It connects UCSI/HOST, Gen1 and external DisplayPort through the exact
Uke PHY, WCD and clock graph. CDC defaults off; the matching root manager enables
it only after an explicit user request. The existing accepted peripheral kernel
remains the rollback. Source, build and device acceptance are separate; see
[the full-profile record](../../docs/USB-TYPEC-FULL-PROFILE-20261018.md) for the
source pins, interfaces, composition requirements and remaining physical gates.

Kernel24 development profile compiles the restricted Uke threshold and positive
FCC interfaces after host guard/transport checks and actual AArch64 OFF/ON
translation-unit checks. Compilation leaves runtime qualification disabled.
The helper's shipped profile is unqualified and admission services remain off;
no threshold/current write, voltage negotiation or physical charging result is
implied. Exact per-boot firmware, protocol, source, cable and protection evidence
remains necessary before control operations. Upstream Kconfig defaults stay off.

## Linux 7.2.11-3 source candidate, 18 October 2026

The79-patch queue adds a restricted one-shot application probe for the already
enabled70/80 charge band. Firmware receipt/readback leaves physical effect
unknown and prevents another fixed writer for that driver instance. General
control qualification remains closed. See the charging-control record.

The separately reviewed AudioReach changes from project commit693dfd4 are
ported to7.2.11 as patch0079. `audio-profile` defaults to `disabled`; optional
`services-only` supplies native APM/PRM ports while DAIs, SLIM and amplifier
buses remain disabled. It creates no sound card or playback/capture path.
The host-only preset inspector never ships in the target package. Source and
software checks do not qualify internal speaker or microphone operation.

## Audio firmware responses, 20 October 2026

The 7.2.11-12 source candidate adds patch 0084. PRM request/release basic errors
reach the existing synchronous DSP error path. APM basic replies are bounded,
and readiness errors must match the active nonzero query token. A successful
basic ACK still waits for the service-specific response. Actual-source GCC and
Clang sanitizer fixtures and AArch64 driver objects pass. The audio profile
remains disabled; full package, admitted firmware and physical audio validation
are separate. PRM stale-response correlation and graph/DMA lifetime remain open.
Patch 0085 also preserves unmap opcode/status, carries the existing buffer-type
token bit and clears only the selected mapping after firmware success. Host
callback checks do not qualify caller-side DMA recovery or graph lifetime.

Patch 0086 serializes PRM transactions with a completion and spinlock. Only
the pending nonzero token, expected opcode and resource parameter can complete
a request. Late/duplicate/unrelated replies cannot overwrite its result.
The module-wide 32-bit sequence survives device reprobe; wire wrap and module
reload are not an unlimited epoch guarantee. Exact firmware token echo and
callback teardown remain separate admission gates. Audio stays disabled.

### Transaction and buffer follow-up, 20 October 2026

Patches 0086–0092 extend the source candidate with correlated PRM replies,
graph payload/period bounds, dynamic-port callback draining, private receive
batches and a sleepable compressed-stream lock. Buffer producers preserve the
ring position after failed sends and carry advertised 128 KiB lengths in an
8-bit index/24-bit length host token. Invalid DMA replies do not publish normal
period progress. These changes introduce no firmware selector or board value.

Actual-source fault fixtures cover the previous failures and the corrected
paths under GCC/Clang ASan/UBSan. Full AArch64 driver objects compile with
`WERROR=1`. Static service/PDR teardown, period reuse/late DMA replies,
caller-side XRUN/error recovery and complete DMA ownership remain open.
Firmware token echo, fitted codec/amplifier, calibration/protection and physical
stream acceptance are separate gates; the native audio profile stays disabled.

Patch 0093 returns graph OPEN errors, retains failed IDs within the current
provider instance and cleans that local metadata at removal. First publication
and final release use the existing provider command mutex; lookups cannot
resurrect a zero reference. This does not establish remote cleanup after a
timeout or a new firmware epoch after manual driver rebind.

Patch 0094 adds the native service quiesce boundary and serialized callback
publication/removal. APM blocks new opens and drains service callbacks before
topology release. PRM releases its children and drains the serialized request
before rejecting further work and disabling callbacks. Process-context and
driver-order fixtures pass; transport/PDR teardown, remote ownership and full
DMA/XRUN recovery remain separate gates. No sound card or route is enabled.

20 October 2026 userdata image refresh: release14 retains source12's94-patch
hardware queue and disabled native audio profile. It restores the explicit
linux/EXT4 and userdata/F2FS root selector from source87eadc3. F2FS and its
security labels are built in; a userdata boot container carries only the bounded
root-profile selector. The current USB/offline-charge paths remain present.
Source tests and package builds do not establish userdata boot acceptance.

## Cliffs7 cache package candidate, 20 October 2026

Release 15 retains release 14's first 94 patch hashes, root profiles, Type-C,
charging and thermal paths. Patches 0095–0097 add the four-bank/v5 Cliffs7
cache provider, five-window binding and managed GPU supplier ordering.
The hashed `llcc-profile` selects `native-v1` during native source preparation;
the generated boot helper transforms only its private admitted DT copy.
Unknown profiles and source/graph mismatches are refused. Audio stays disabled.

The reviewed root selector also forwards exact `_a`/`_b` boot-slot identity and
an explicit `msm.o82_vrr_test_min_hz=0|30` only with the userdata root selector.
Duplicates, malformed values, forced-argument conflicts and insufficient space
are rejected before command-line mutation. Other bootloader arguments remain
excluded. The standard Linux container does not enable the VRR experiment.

The local source RPM passes fresh 97-patch preparation and three native
AArch64 objects with KCFLAGS=-Werror. These results remain separate from a
full kernel/package build and tablet acceptance. Actual bank/version
admission, partial-programming recovery, GPU lifetime, cache coherency,
suspend and any performance gain remain unqualified. Keep the accepted kernel
and its matched modules available for recovery.

## Native firewall and root policy candidate, 20 October 2026

Release 16 retains the 97-patch hardware queue and adds the modules required
by the original firewalld nftables backend: mixed IPv4/IPv6 tables, connection
tracking, NAT, masquerading, redirection, rejection, rate limits, logging and
FIB lookup. Source and resolved-configuration checks pass; package checks also
require the corresponding built modules. This does not establish a running
tablet firewall or change network rules during an SSH session.

The forced command-line parser selects only `rootfstype=ext4` for the Linux
profile or `rootfstype=f2fs` for userdata. Userdata changes `panic=0` to
`panic=10`; Linux retains its bring-up setting. Duplicate or changed forced
defaults are refused before mutation. Embedded dracut defaults exclude these
fields so they cannot override the selected profile. GCC and Clang ASan/UBSan
fixtures cover both profiles, all field orders, rejected input and capacity
boundaries. A panic restart is separate from hard-hang recovery or physical
A/B rollback qualification. No tablet installation or reboot is implied.

## Audio service registration, 22 October 2026

The 7.2.12-10 candidate selects the existing `services-only` audio profile.
Native APM/PRM services 1/2 can bind and perform the bounded firmware readiness
query; original clients 3/7 remain present. Both DAI children, amplifier I2C
and SLIM remain disabled. The package does not create playback/capture paths
or apply microphone bias, amplifier presets or calibration. The existing
`disabled` preparation setting remains available for rollback/source comparison.
Host FDT and actual-source response/lifetime checks precede COPR submission.
Tablet service binding and physical internal audio remain separate tests.

## Audio card registration candidate, 22 October 2026

The 7.2.12-14 source selects `registration-only`: the native APM and PCM
components register a Uke card with playback/capture frontend descriptions.
The displayed names explicitly mark streams disabled. The q6apm component
refuses both PCM and compressed opens before DSP graph allocation, rather
than relying on the later machine startup callback. It also skips PCM buffer
construction and teardown mappings, which source review found unguarded in
the uninstalled release-12 candidate. No backend, amplifier,
microphone bias or SLIM path is enabled. Native card visibility and physical
audio acceptance remain separate results.

Release 13 registered the card after a manual module load on the tablet, but
cold autoload failed through the original Fedora ALSA rule's missing
`snd-seq` dependency. Its frontend IOMMU attachment also triggered warnings
outside the guarded boot scope. Release 14 includes the sequencer module and
omits that attachment while frontend DMA remains prohibited. The original
Fedora rule and SMMU guard are retained; cold-boot validation is still required.

Original host `alsatplg` from Fedora `alsa-topology-utils` compiles the project frontend
description; no donor build script is executed. The output contains no
calibration, graph endpoint or mixer and is installed below the exact kernel
release's firmware search directory. The host ACDB metadata inspector and its
fixtures are source/build tools only and do not enter tablet payloads.

## USB and display diagnostics, 24 October 2026

The native configuration already enables `CONFIG_DYNAMIC_DEBUG` and debugfs.
Release 27 adds optional PAN event, QMP request and per-provider mux result
messages. These sites are silent until enabled; enabling them does not change
roles, PD policy, routing or power sequencing. Record the existing debug flags
and `/sys/module/drm/parameters/debug` value before each controlled test.

For example, enable the three routing files during a root diagnostic session:

```sh
printf '%s\n' \
  'file drivers/usb/typec/mux.c +p' \
  'file drivers/phy/qualcomm/phy-qcom-qmp-combo.c +p' \
  'file drivers/soc/qcom/pmic_glink_altmode.c +p' \
  | sudo tee /sys/kernel/debug/dynamic_debug/control
```

Existing DWC3, hub, UCSI and DP/AUX diagnostics can be selected by file or
function as needed. Restore the previous flags and DRM mask after capture;
use `-p` for sites whose print flag was initially disabled. Keep raw traces
private. These messages describe control state and do not dump USB payloads.

## DP stream source candidate, 24 October 2026

On POCO Pad X1 with signed release 27, Juo JH925 and ViewSonic VA3209-QHD,
HDMI reattachment produces HPD, EDID and successful HBR2 two-lane training.
The monitor detects the connection but remains black. Both 2560x1440 at 75 Hz
and 1920x1080 at 60 Hz fail to prepare the DP pixel clock with `-EINVAL`.
Clock tracing shows a zero cached pixel-source rate; initial PHY parent setup
also reports inactive pixel RCGs above their unchanged OEM Fmax limits.

Release 28 defers voltage rate-change callbacks for unprepared DP pixel RCGs
until their actual output is configured. Prepare-time validation and prepared
clock voltage votes remain in place; clock tables and DSI behavior are unchanged.
It also suppresses unchanged HPD-level reports without dropping firmware ACKs,
route application or IRQs. Source-extracted fixtures pass; native package and
tablet validation remain required. The settings overlap reported in the same
trial is not yet causally assigned to the repeated hotplug path.

On 24 October, signed release 28 produces an operator-confirmed HDMI image and
mouse input through Juo JH925 on ViewSonic VA3209-QHD at 2560x1440/75 Hz. The
internal panel remains a separate display. Cover/panel transitions can still
trigger a firmware-reported disconnect and USB controller removal. HDMI audio
has no connected PCM backend; the registration-only internal card stays closed.

Release 29 corrects non-EDID I2C transaction handling. The EDID helper must not
inject offset writes into DDC/CI address 0x37. The existing `no_zero_sized` DRM
contract marks the final payload so the callback can send its STOP, while EDID
segment handling remains in place. Actual callback fixtures pass against a host
protocol model. Native package, physical DDC/CI and brightness readback remain
separate gates. This change does not claim HDMI audio or USB/lid stability.

The Uke-only `uke_dp_lane_limit` sysfs attribute sets a nonpersistent 1/2/4-lane
training ceiling while no sink or stream is present. Attachment still obeys
source, sink, LTTPR and USB-C firmware limits. It does not select Type-C pins,
raise the HBR2 ceiling, or establish four-lane, MST or USB fallback acceptance.

25 October 2026: release 38 restores the inherited-framebuffer console after
the release-37 experiment retained the pale-gray interval. The WLAN regulator
lifetime correction remains. Bounded boot messages report existing Uke display
voltage/sync, SMMU mappings, backlight and MDSS ownership state without new
register reads, power/clock writes or timing changes. Cliffs interconnect sync
still invokes the original callback. These are diagnostic observations;
physical gray-screen and repeated-startup qualification remain open.

25 October 2026: normal 7.3.0-9 enables the standard DRM DP AUX character
interface for receiver-capability diagnostics. This preserves the release-6
video implementation, the reviewed OEM video configuration gates and the
accepted display isolation. It adds no DSC/FEC activation, Type-C pin override
or display timing change. Verify node permissions and receiver capabilities
on the tablet before qualifying external DP compression.

25 October 2026: release 10 notifies the registered PCM ELD control when the
SM7675 DP codec's cached monitor bytes change at startup or hotplug. The
notification uses the actual registered PCM device and is absent before
control registration or after component removal. Foreign DP parents retain
their original behavior. Monitor-name persistence and audio hotplug require
separate tablet acceptance; host fixtures do not establish those results.

27 October 2026: source candidate 23 connects the exact contiguous Cliffs
ICE/HWKM windows to the upstream host-owned ICE path. It adds the native
`ice_core_clk` name and the OEM 100--403 MHz frequency range while retaining
the existing always-on UFS GDSC providers. Admission requires all five OEM
resource pairs and the matching shared-ICE allocator; unqualified layouts
are rejected before overlay application. Upstream retains SCM, version and
fuse checks and the default raw-key policy. No Android key, storage layout or
root mount is changed. MCQ integration, a full matched build, recoverable boot
and isolated inline-encryption I/O acceptance remain pending.

27 October 2026: source candidate 24 adds the separate OEM Cliffs MCQ
operation and status windows. The native driver derives queue-configuration
placement from QCFGPTR, bounds it between the ICE/HWKM and vendor regions,
and unwinds partial mappings before the core's existing SDB fallback. The core
also retains working SDB DMA buffers until every MCQ allocation succeeds and
restores buffers and queue counts on failure. Other controllers retain their
existing mapping. The standard main-IRQ completion
handler remains in use; poll queues are excluded from that handler. Host
fixtures cover resource/queue limits, all mapping failures, generic-controller
behavior, actual core completion dispatch and DMA allocation failure/rollback
without reducing the supported tag count. Matched boot, storage I/O,
error recovery and suspend/resume acceptance on Uke remain pending.
