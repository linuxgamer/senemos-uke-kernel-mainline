# Native Binder prerequisite

3 November 2026. Release `7.3.1-1302` enables the original Linux Binder IPC
driver and binderfs as built-in features in the ordinary ARM64 kernel. Static
Binder devices are disabled; a container manager can create private devices in
binderfs. Memfd remains enabled. KVM, Gunyah VM management and EL2 takeover are
independent of this Waydroid prerequisite.

The COPR-only source worker is
`packaging/native/copr-binder1302.sh`. It starts from the complete release1301
SRPM in COPR11251200, verifies its SHA-256 and retained source inventory, and
changes the native configuration in both the profile and boot recipe. The boot
recipe lock follows the actual configuration bytes. All driver sources, OEM
supplier selection, MEMLAT groups, bounded touch recovery and package lifecycle
scripts remain those of the parent.

The native RPM checks require the effective configuration, compiled Binder and
binderfs objects, and both initialization symbols in the linked kernel. These
checks establish packaged kernel support. A boot into the matching kernel,+binderfs/device operations and an ARM64 Waydroid session require separate
physical validation. This change does not install or start Waydroid.
