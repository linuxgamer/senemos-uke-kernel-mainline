# O82 supplier variant build

The 3 November 2026 candidate uses `copr-o82-variants731.sh` to compose
`7.3.1-1100` from the successful release1011 source RPM (COPR build11246385).
The pinned parent includes the release1010 production drivers and versioned
device-local video firmware import. The source worker verifies its SHA-256,
retains unrelated sources and package scriptlets, and records every overlay.

The candidate adds early selection of O82-36/O82-42 device trees, their Tianma
and CSOT touch profiles, and complete PM8010 inventory validation. A separate
prepare patch carries these changes onto the parent; it excludes the later
USB role experiment present in the default main-branch preparation script.
The native profile and boot recipe each retain verified source receipts.
No firmware binary or per-device calibration is included.

This is an opt-in Fedora Rawhide AArch64 test build. COPR must complete the
kernel, modules, boot image and existing package checks before installation.
Compilation does not establish boot success or O82-36/Tianma hardware support.
Physical acceptance remains open for each supplier variant.
