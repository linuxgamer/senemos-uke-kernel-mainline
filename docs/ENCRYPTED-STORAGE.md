# Encrypted storage

1 November 2026. Uke / SM7675, Fedora Rawhide AArch64. The storage candidate
retains the qualified Linux 7.3.1-115 source and enables standard kernel
encryption facilities. Source/configuration checks are separate from native
package, encrypted I/O, encrypted-root boot and performance acceptance.

| Filesystem | Whole-volume encryption | Filesystem encryption | Inline hardware path |
|---|---|---|---|
| EXT4 | LUKS2 / dm-crypt | fscrypt | fscrypt or dm-inlinecrypt |
| F2FS | LUKS2 / dm-crypt | fscrypt | fscrypt or dm-inlinecrypt |
| XFS | LUKS2 / dm-crypt | Not provided by this profile | dm-inlinecrypt |
| Btrfs | LUKS2 / dm-crypt | Not provided by this profile | dm-inlinecrypt |

The common whole-volume path does not depend on filesystem-native encryption.
The kernel includes device mapper, dm-crypt, dm-inlinecrypt, AES-XTS and ARM64
AES instructions before root mount. Existing Qualcomm ICE/MCQ resources,
clocks, power policy and firmware remain unchanged. Software fallback supports
encryption when inline hardware does not support a requested mode. Optional
dm-integrity, dm-verity, fs-verity and UFS temperature monitoring are available;
they are not enabled on an existing volume by installing the kernel.

The original Fedora `cryptsetup` package is recommended. The candidate does
not introduce a project key manager, private signing key or target Python.
Keep keys out of command arguments, logs, boot images and public artifacts.

The running 7.3.1-115 profile exposes raw-key AES-256-XTS capability, 64 ICE
keyslots and 64 DUN bits. Registration is not encrypted-I/O acceptance.
Hardware-wrapped keys, Android KeyMint/RPMB access and another board's trust
configuration are not qualified by that observation.

[dm-crypt](https://docs.kernel.org/admin-guide/device-mapper/dm-crypt.html)
uses the regular Crypto API; ARM64 CPU AES acceleration and UFS ICE are
different paths. Current [dm-inlinecrypt](https://www.kernel.org/doc/html/v7.3/admin-guide/device-mapper/dm-inlinecrypt.html)
does not have standard cryptsetup/LUKS userspace integration. Its kernel
support is available for qualification, not an automatic LUKS hardware mode.
[fscrypt](https://docs.kernel.org/filesystems/fscrypt.html) encrypts contents
and names, while leaving other filesystem metadata visible.

## Boot and migration boundary

An encrypted data volume and an encrypted system root require different
integration. The existing root guard still admits a provisioned filesystem on
the physical `linux` or `userdata` partition. Do not format or convert the
running root. Encrypted-root admission must preserve physical UFS identity,
authenticated mapping, interactive unlock, matched update/fallback handling
and independent recovery before it is qualified. Existing plaintext boots
and rollback images retain their current policy.

## Performance qualification

Use the same device, kernel, filesystem features, usable capacity, data set,
queue depth, power and thermal state for plaintext and encrypted comparisons.
The target is at most 5 percent throughput loss and 5 percent added p95
latency for the agreed workload. This is an engineering target, not a measured
result. Also record CPU use, energy, temperature and sustained-write behavior.

Validate sequential and random reads/writes, fsync, verification after cold
boot, wrong/removed keys, slot exhaustion and reset/resume. A loop/RAM result
does not demonstrate UFS hardware encryption. Keep software fallback visible
when attributing performance to ICE. Do not disable flushes, barriers, integrity
requirements or key derivation for benchmark scores. Discard and workqueue
changes require their own measured privacy/performance decision.
