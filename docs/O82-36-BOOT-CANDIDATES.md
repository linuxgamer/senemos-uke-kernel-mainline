# O82-36 startup candidates

3 November 2026. These source candidates address differences from the Xiaomi
Pad 7 O82-36 working r1 reference. Neither is a diagnosed boot fix or a hardware
acceptance result. The working O82-42 startup must retain its existing behavior.

## Controlled comparison

| Kernel | Difference from previous row | Purpose |
| --- | --- | --- |
| 7.3.1-1102 | Existing supplier support and native NFC/IR package ABI | Baseline; differs from R5 1101 only in NFC/IR packaging metadata and its check |
| 7.3.1-1103 | Prefer O82-36 at 60 Hz | Separate the initial mode from command transport |
| 7.3.1-1104 | Serialize O82-36 ON, TP-FPS and normal-pixel commands; omit its extra dimming group | Compare the supplier-specific working reference transport with 1103 |

All seven fixed rates remain advertised; advertisement is not physical
qualification. O82-42 keeps preferred 120 Hz and its existing batched startup.
The serial candidate retains the existing advisory-read policy, asynchronous
first-frame boundary, touch notifier, firmware admission, module signatures,
root selector and boot construction. Transport and dimming omission are coupled
to reproduce the reference startup protocol; do not attribute any observed
improvement to an individual packet change without another experiment.

The native source recipes retain the exact release1011 SRPM, SHA-256
`84915ef98a26df47bc8f223e3751b160e40eba3c447f433fbe13b2097d6a7146`,
and explicitly inventory their overlays. No firmware bytes are embedded.
Use `copr-o82-mode60.sh` for 1103 and `copr-o82-serial60.sh` for 1104.
Run compilation and fixtures in a Fedora Rawhide AArch64 COPR worker.

Reference: linuxgamer/senemos-uke-kernel-mainline at
`c1cf84f4276245550f61b1df71127278fc5dae87`,
`src/display/panel-xiaomi-o82.c`. The reference is GPL-2.0-only, as is this
driver. Uke OEM packet data and the current lifetime/error handling are retained;
no other board's GPIO, timing, supply or firmware settings are imported.

## Boot-stage decision record

1. A bootloader rejection needs the selected image hash, accepted header and
   failed-state slot variables. Recovery's filesystem error does not establish
   a Linux root-mount failure.
2. Kernel entry followed by `Uke ABL DT adaptation rejected` identifies early
   tree admission. Retain the exact reason and selected panel; do not relax
   unknown, duplicate or malformed selector refusal.
3. Initramfs root-selector/guard messages distinguish header handoff, physical
   UFS discovery and filesystem label failure. The R5 embedded initramfs exists
   even though the Android v4 header has zero external ramdisk bytes.
4. A real-root journal boot ID proves systemd entry. Native DRM errors and
   missing first-frame completion then distinguish panel/GPU from later KDE.
5. First-frame completion followed by missing native input requires the
   NT36532 supplier, firmware admission and startup-calibration logs.

Current failure stage remains unknown. R5 1101 has userdata `panic=10` but
does not contain the newer opt-in boot-reset or initrd deadline mechanisms.

## Acceptance and rollback

Source checks, COPR compilation/package checks and physical results are separate.
Record the exact Image, modules, DT, signer/vermagic and matching boot RPMs from
one build. Never mix these two kernel releases. Before installation retain the
known-good complete boot/module set and its recovery route. No automated flash,
slot switch, package installation or reboot is part of these recipes.

O82-36 and O82-42 physical boot, every advertised rate, brightness, GPU rendering,
native touch and independent contact lifts, suspend/wake, cover, audio,
connectivity, charging, thermals and rollback are **not run** for these candidates.
Host/build passes cannot change those entries. Preserve firmware and security
policy. Stop a device trial at its first new failure and preserve logs.

The next discriminating test is the same O82-36 image/profile at 1102 then
1103, followed by 1104 only if 1103 still fails. Check exact image hashes and
capture the first available failed-boot pstore/journal before restoration.
Keep the userland, firmware and slot constant for this comparison.
