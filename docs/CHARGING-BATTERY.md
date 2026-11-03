# Uke charging source candidate — 18 October 2026

Base: 99c20362d7be332bc8f33c58424b7c014fffd120. Planned 7.2.10 package
release: 9, not built or published. The previously accepted release remains a
separate fallback. Both 7.2.10 and retained 7.2.9 patch lists carry 0050/0051;
only a future applied-source build can establish compatibility with each base.

0050 correlates exact-Uke replies, cancels interrupted requests and keeps an
ambiguous transport instance unavailable. Notification-enable waits for a
matching bounded envelope under the request mutex; its opaque payload is not
interpreted as successful feature activation. 0051 gives gadget requests a
sequence and absolute retry deadline while retaining the bounded SDP admission
and supplier device link. Neither patch raises ICL or opens battery setters.

Read-only uke_battmgr_state exposes event/firmware generations and a driver
instance receipt token. They do not replace a firmware attach/PD contract ID.
Per-field physical measurement time and cache age are not supplied by this ABI.
A lost/ambiguous SET is not replayed; failed communication does not establish
physical charge interruption. Existing ADSP recovery remains disabled.

The OEM envelope does not echo a transaction ID. After timeout or interrupted
pending I/O, PDR up/resume alone cannot prove a drained transport. A clean
transport/boot boundary is required; live module reload is not an accepted
recovery path. Source-event changes after AP admission can still race an
untagged remote SET. That hardware/firmware boundary remains an acceptance item.

No tests, syntax checks, source application checks, builds, packages or tablet
commands were run at the user's request. Prepared host entry points, for a
later joint session after preparing the selected kernel source, are:

- `bash tests/battery-coordinator-contract.sh <prepared-kernel>`
- `bash tests/battery-protocol-contract.sh <prepared-kernel>`
- `bash tests/usb-charger-readiness-contract.sh <prepared-kernel>`
- `bash tests/serial-power-budget-contract.sh <prepared-kernel>`

The SRPM recipe refuses a dirty source snapshot because its native archive uses
`git archive HEAD`; adaptation bytes and the archived native profile must agree.
Commit the reviewed local source only after the joint source checks, then build
the complete matched boot/kernel/DT/module tuple. No build or commit occurred in
this preparation session.

The hardware-support platform-runtime observer is read-only and optional. See
its `docs/BATTERY.md`. Canonical source comparison, ownership/profile gaps,
protection inventory, 60 requirements and all deferred H/D cases are in
`uke-linux-docs/docs/research/UKE-CHARGING-IMPLEMENTATION-2026-10-18.md` and
`uke-linux-docs/docs/testing/UKE-CHARGING-2026-10-18.json` in the workspace.
