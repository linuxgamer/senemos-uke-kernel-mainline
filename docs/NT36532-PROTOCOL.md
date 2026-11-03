# NT36532 Uke protocol and transport candidate

3 November 2026: the exact Uke
[board DT](https://github.com/MiCode/kernel_devicetree/blob/94c84aeb9e517dbde546fc732033c184094c8e57/qcom/uke-sm8635.dtsi#L184)
declares `novatek,NVT-ts-spi`, SPI chip select0,19.2 MHz maximum, IRQ GPIO54,
supplier-ID GPIO26, `novatek,pen-support` and `novatek,stylus-resol-double`.
Its5993/5994 children contain supplier-specific manufacturing criteria.
This is configuration for the OEM driver, rather than its C implementation.
Adding its boolean pen properties does not provide a native packet decoder.

The native driver below already handles the admitted finger protocol and
supplier firmware selection. Pen coordinates and tilt remain unimplemented.
The selected adjacent MiCode common framework accepts already-computed pen
values from userspace; it does not establish Uke's raw-matrix coordinate
algorithm. No adjacent-board pressure limits, packet offsets or firmware are
enabled from that comparison. Pen support still requires the exact normal
frame contract, lifecycle and separate accessory validation.

2 November 2026: source profiles now retain separate CSOT and Tianma normal
firmware hashes, CRCs and DT electrode maps. A mismatched supplier image is
rejected before RAM writes; all banks are still read back. See
[variant selection and test limits](O82-PANEL-VARIANTS.md). The O82-36/Tianma
association and physical input remain unverified; adjacent-device GPIO polarity
is not substituted. Earlier CSOT-only records below retain their original scope.

23 October 2026. Host C fixtures and AArch64 Linux 7.2.12/7.3 objects.
The tablet continues to use the packaged userspace touchscreen implementation.

`src/input/nt36532-uke-protocol.c` contains the GPL-2.0-or-later normal RAM
download, raw-frame admission, watchdog and charger-noise protocol. It derives
from the same separately licensed `touch-normal-probe.cpp` and
`touch-thp-packet.hpp` retained in the reviewed `uke-hw` source archive.
It does not include the GPL-3 userspace wrapper or Apache-licensed contact
processing algorithm.

The comparison sources are MiCode touch revision
`15798a6c73e37643c627c00579932fd483a7fcc8`
(`p81/nt36532/nt36xxx.c`, `nt36xxx_fw_update.c`, `nt36xxx_mem_map.h`), Uke OEM
kernel `5712080a4b0c0b1a879e6d145c601c649ddaddfd` and DT
`94c84aeb9e517dbde546fc732033c184094c8e57`. The existing Uke protocol and
protected firmware identity select the exact bank layout; adjacent tablets'
coordinate parsers and board settings are not substituted.

The consumer supplies bounded SPI callbacks, SHA-256 and a panel-readiness
check. Every transfer and final successful operation checks readiness; the
future transport must serialize panel generation changes with transfers.
Callbacks return zero on complete success or a negative errno. Positive
results are rejected. Image size, header and full SHA-256 must match before
device I/O. All four banks are read back before boot-ready is written.

A validated 5,432-byte frame retains its counter, scan type and 2,400 signed
little-endian raw nodes. The returned matrix pointer borrows the caller's
frame buffer. The values are not labelled as signed deltas: reference
subtraction still belongs to the existing contact processor.

## Host checks

`make test-touch-protocol` compiles the actual C file and injects failures at
380 individual transfers and 382 readiness checks. It also checks corrupt
packets, image refusal, foreign chip/topology, bank mismatch, timeouts,
operation-mode responses and charger-command readback. The default fixture's
synthetic SHA callback tests control flow, not cryptographic admission.

Optional private inputs extend the same test runner:

```sh
UKE_TOUCH_REFERENCE_DECODER=/private/source/touch-thp-packet.hpp \
UKE_TOUCH_NORMAL_IMAGE=/private/normal.bin \
UKE_TOUCH_SANITIZE=1 bash tests/touch-protocol-contract.sh /private/frame.bin
```

The original C++ decoder and this C implementation agreed on 10,000 generated
frames, 80,000 mutations, 10,000 watchdog packets and one retained private
frame. An independent OpenSSL SHA-256 check admitted the retained normal
image and rejected one changed byte per 1 KiB. GCC ASan/UBSan checks passed.
The AArch64 object compiled against the prepared project Linux 7.2.12 source
with Clang 23.1.3 and `KCFLAGS=-Werror`; this is not a linked driver build.

## SPI and capture candidate, 23 October

`nt36532-uke-spi.c` supplies mode-0 SPI, a threaded rising-edge IRQ and a
V4L2 metadata queue. The page command uses 1 MHz; firmware RAM and complete
5,434-byte frame transactions use 19.2 MHz. Controllers unable to transfer
one whole packet are refused. Short transfers, oversized/overflowing addresses,
state changes and stale generations abort the operation.

The queue uses `V4L2_META_FMT_GENERIC_8`, one 5,432-byte line, through a
`VFL_TYPE_VIDEO` metadata node. This preserves every packet byte and does not
mislabel signed raw values as signed deltas. Only host-root credentials may
open the raw node. The contact processor still owns private reference
subtraction and uinput. A video-group or seat ACL does not grant raw access.

O82 `.enable` schedules asynchronous first-frame work. The standard panel
follower's enable notification is therefore too early for firmware download.
The candidate exports a synchronous notification at the existing actual
`touch_reset_state` transitions, including an atomic registration snapshot.
Panel reset invalidates the transport generation, drains IRQ/work/transfers,
then permits panel power changes. A worker never acquires a panel mutex.
Suspend, shutdown, stream stop and removal quiesce the same transport. V4L2
references retain capture storage for file descriptors surviving unbind.

The normal-image hash and four-bank readback remain mandatory. Watchdog
recovery reloads that same image. Standard `power_supply` notifications apply
the existing charger-noise command with readback; missing telemetry does not
invent a charger state or disable touch. No charging-control command is added.

The active OnePlus Pad 2 queue at `127ee601667aa3ac0125138573176f512cb70292`
selects coordinate driver 0018, but comments out watchdog patch 0021. Lenovo
TB520FU `972c5ce4d2955bb0382a2101f4e22c5185cea6ba` selects SPI patch 0821
and panel-ordering patch 0832. Those coordinate firmware/packet contracts
do not replace Uke THP. Current upstream DRM follower, V4L2 metadata,
videobuf2 unregister and device-reference APIs supply the lifecycle framework;
no donor board settings, firmware or contact code are copied.

`make test-touch-transport` executes the production SPI and lifecycle functions
with short/error transfers, every admission flag, stale IRQ generations,
charger failures and 100 concurrent in-flight panel resets. It also executes
the production O82 registration/state/unregistration functions. Clang
ASan/UBSan and complete source validation passed. Both the composite transport
object and panel object compile against prepared Linux 7.2.12 and 7.3 with
Clang 23 and `-Werror`. These are object checks, not full module/modpost builds.

## Remaining integration

Kconfig and an explicit host-only staging helper exist; normal release
preparation and configuration do not select this driver. DT binding/selection,
private firmware-path provisioning and the existing C++ contact consumer must
be integrated together before replacing the current transport. Suspend,
resume, generation changes, watchdog recovery and physical touch/VRR
continuity then require separate tablet tests. The standalone touchscreen
package remains necessary until that replacement is qualified.

Private firmware and reference data are not distributed with this source.

## Source correction, 30 October 2026

The transport and integration descriptions above record the 23 October
candidate. They do not describe the active source at `768ff06994d7bab601067a8664d63ba2502399d3`.
`src/input/nt36532-uke-spi.c` now publishes finger contacts directly through
the Linux input subsystem, using `input_mt_assign_slots`, `MT_TOOL_FINGER`,
`ABS_MT_POSITION_X` and `ABS_MT_POSITION_Y`. It also exposes `KEY_WAKEUP`.
The current driver is not the V4L2 metadata/uinput architecture described
above. `tests/touch-runtime-package-contract.sh` checks the native-input
payload guard used by `packaging/senemos-uke-linux-kernel-mainline.spec`.
`manifests/touch-runtime.json` and `scripts/stage-touch-runtime.sh` retain
the older capture-client route and must not be used to infer the current
package architecture. Source selection does not establish the running
tablet's driver or successful suspend/resume.

This input registration does not expose `BTN_TOOL_PEN`, pressure or tilt axes.
Finger contact tracking is therefore not evidence of Xiaomi Focus Pen
support. Before adding pen decoding, identify any separate evdev/HID path
and its exact packet contract on the target. Pressure, hover/contact,
buttons, reset/disconnect release and optional tilt need independent evidence
and fixtures. Do not substitute another tablet's coordinate constants or
invent proximity/pressure values. No physical pen test was performed for
this source correction.
