# O82 supplier variant build

The 3 November 2026 candidate uses `copr-o82-variants731.sh` to compose
`7.3.1-1102` from the successful release1011 source RPM (COPR build11246385).
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

Release1100 completed the kernel, modules and both boot bundles in COPR
build11247756. Its final DSI transaction fixture still treated O82-36 as a
foreign panel and stopped package checks. Release1101 corrects the fixture's
single-supplier model, uses a genuinely foreign panel for refusal checks and
executes the seven-mode and refresh-transition matrices for both suppliers.
The runtime variant sources are retained; a fresh ABI avoids reusing the
release1100 module-signing identity. The repeated complete build passed as
COPR11247906.

Release1102 adds a versioned native NFC/IR capability and the matching
`uke-nfc-ir` session-access dependency. Package checks inspect the real linked
FM19511/IR modules and their DT autoload aliases. The existing exact Uke DT
and POCO SKU admission remain authoritative. This candidate has not yet been
submitted; kernel feature integration is still in progress.
