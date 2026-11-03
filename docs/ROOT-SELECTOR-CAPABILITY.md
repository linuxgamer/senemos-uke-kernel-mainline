# Root-selector capability declaration

The source boot producer emits one allocated ELF64 note through Linux's
`ELFNOTE64` helper. It declares the bounded argument parser ABI; it does not
enable private VRR or establish display/boot qualification.

| Field | Version 2 |
| --- | --- |
| Byte order / alignment | Little-endian / four bytes |
| Note name | `UKE` including its terminating NUL; namesz 4 |
| Type | `0x554b4501` |
| Descriptor | `root-selector-v2;userdata=f2fs,ext4,xfs,btrfs;slot=a,b;vrr-min=0,30` including its terminating NUL; descsz 68 |
| Padding / total length | Four-byte alignment / 84 bytes |
| Boot manifest property | `root_selector_capability=uke-elfnote-v2` |

22 October 2026. V2 retains the complete userdata filesystem probe list and
requires built-in EXT4, F2FS, XFS and Btrfs. The physical UFS root guard admits
only the selected `UKE_LINUX` userdata filesystem; Btrfs must have one member
and a unique UUID among discovered block devices. Legacy `linux` remains EXT4.
The initrd offline grower runs only for F2FS. Other formats use the separately
packaged, completion-gated original systemd-growfs before login. This source
contract does not establish native Uke boot support for a new filesystem.

`__used` in the upstream helper forces compiler emission. The ARM64 kernel's
`RO_DATA`/`NOTES` linker rule retains `.note.*` through `KEEP`. The note is emitted
by the same header as the parser in the Uke ABL translation unit. Source and
package configuration checks remain necessary; the declaration is not code
attestation.

The host producer checks exactly one complete aligned note in the final raw
Image before creating either boot wrapper. `check-root-capability.sh` checks
header sizes, name, type, descriptor, NULs and padding, rejecting absent,
duplicate, malformed and unsupported declarations. Parser text or descriptor
text alone is insufficient. A consumer must also verify the signed package,
matched manifest, unchanged extracted Image and normal update/rollback gates.
No kernel hash allowlist substitutes for those checks.

The source lock records the same declaration. The native package check runs
`root-selector-note-contract.sh` with its prepared kernel source and boot recipe
lock. It uses the actual Linux ELFNOTE macro, LTO and linker garbage collection,
plus rejection fixtures. The host and AArch64 object/link fixtures do not qualify
a complete boot image; the coordinated kernel build must pass the final Image
check before delivery.

The boot RPM requires both `uke-kernel-update >= 1.3.1` and
`uke-kernel-update(guarded-automatic) >= 1` as ordinary, lasting dependencies.
The guarded consumer must be present when the kernel's post-transaction hook
runs and remain installed afterwards. A `Requires(posttrans)` declaration alone
does not provide a lasting requirement or order package installation. The
consumer must apply its global/profile gate without relying on another
package's post-transaction initialization. This source change is reserved for
the next coordinated kernel release. The singleboot child additionally requires
`uke-kernel-update(root-filesystem-v2) >= 1` and installation profile 1.3.1;
an old consumer must not stage a v2 userdata bundle. Published v1 images remain
usable with the new consumer on F2FS; they are refused for the other formats.
