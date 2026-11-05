# Senemos Uke Mainline Kernel

Linux kernel adaptations, device trees and Fedora RPM packaging for Xiaomi Pad 7 and POCO Pad X1 (`uke`, Snapdragon 7+ Gen 3 / SM7675).

**Target:** Linux 7.3.x · AArch64 · Fedora Rawhide  
**Status:** Active development

[Uke Linux](https://github.com/MCC45TR/uke-linux) · [Hardware support](https://github.com/MCC45TR/uke-linux#hardware-support) · [COPR packages](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/) · [Build documentation](docs/BUILDING.md)

> [!WARNING]
> This is an experimental kernel. Keep a working boot image and matching modules before updating. Not every source change has been tested on the tablet.

## Development status
4 November 2026. New development and candidate builds use
`senemos-uke-linux-kernel-mainline-unstable` with an `-unstable` Image ABI.
Normal-family updates require an explicit request and physical qualification
before promotion. The legacy upstream-update workflow and normal COPR webhook
rebuilds are disabled.

The tablet now runs `7.3.1-11003-unstable`, qualified in
[COPR 11260288](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11260288/).
Its complete source combines the read-only RTC gate, CAMCC stage1, paired
HSIC/SixZone v4 color source, CDSP/pogo, corrected network configuration and
I2C-owned NFC wakeup. Boot observation does not establish full peripheral,
calibrated camera or color/HDR acceptance.

Read-only SSC discovery observations passed
[COPR 11260554](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11260554/):
actual callbacks, reconcile failure cases and native driver compilation.
The cumulative source producer pins the complete 11003 SRPM and composition,
preserves every undeclared source byte and adds only those qualified sensor
changes plus the new ABI's audio identity.
The older 7300-based color producer remains held to prevent source regression.

The cumulative `7.3.1-12000-unstable` candidate passed
[COPR 11260662](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11260662/):
Image, signed modules, both supplier DTs, boot/RPMs, retained controls and all
ten SSC observation callbacks. All six AArch64 packages and the source RPM are
present in checksum-verified root metadata. The packaged composition preserves
11003 and adds SSC observations. The tablet remains on 11003; physical sensor
acceptance is pending. This build predates the shared integration directive;
the camera conversation owns further cumulative builds and delivery.

The coordinator has staged `7.3.1-12101-unstable` through DNF; an observed boot
is pending. Future integration preserves that candidate and subsequent feature
handoffs. The older SSC-only source producer is held to prevent regression.

5 November 2026. Native memory-color/protection programming passed
[COPR 11260889](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11260889/):
paired byte encoding, all register readbacks, failure ownership and a linked
MSM object. Named endpoint conversion and the current payload bridge passed
[COPR 11260921](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11260921/).
A separate v5 memory-payload loader passed
[COPR 11261036](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11261036/)
for both supplier identities with strict version/fallback checks.
The production JSON/v5 path and native utility0.6.0-3 passed
[COPR 11261174](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11261174/):
1,024 complete JSON/bundle/actual C loader cases and12,288 paired command
streams per compiler. The native RPM is present in verified root unstable
metadata. The reusable source layer also passed
[COPR 11261282](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11261282/)
on complete12101 with qualified touch and front-camera geometry: four source
rejection controls, exact repeated application, inherited preflight and a linked
AArch64 MSM object. Both supplier DT resources and raw configuration remain
unchanged. The [qualification manifest](manifests/o82-memory-cumulative-source-20261105.json)
records the exact source and receipt. Full cumulative kernel delivery, private
profile preparation and physical memory-color/protection/HDR acceptance remain
open. Existing v4 loading keeps memory absent; initial color selection is empty.

Utility `0.7.0-1` adds private preparation from the fitted panel's exact stock
ODM profile and passed
[COPR 11261358](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11261358/).
GCC and Clang ASan/UBSan pass candidate admission, private permissions,
unchanged repeated preparation, failed-write cleanup and concurrent publication,
with retained color conversion and actual kernel-loader checks. The native RPM
is available in verified root unstable metadata and contains no factory tables.
The [source manifest](manifests/o82-stock-profile-source-20261105.json) records
the exact inputs. Coordinator DNF integration, device-local preparation and
physical acceptance remain pending; kernel/profile selection is unchanged.

Private preparation now has a qualified DNF integration path in boot userspace
`1.8.95`, [COPR 11261509](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11261509/).
The [kernel metadata layer](manifests/o82-private-dnf-source-20261105.json)
adds exactly two boot dependencies and one RPM-owned manifest marker, retaining
the final transaction path and every other spec/profile/config byte. The
coordinator must include it in the next complete memory/v5 kernel; the installed
12101 candidate is unchanged. No preset, DMA or HDR gate is enabled.

31 October 2026. `main` is the continuation branch. Microphone capture, power management, bounded boot-watchdog and optional gaming sources are integrated. The complete combined source still requires fresh release admission and a qualified COPR build; retained candidate packages do not establish that result.

On POCO Pad X1 with Fedora Rawhide AArch64 and kernel `7.3.1-102`, one named four-channel microphone input records all four paths. The operator accepts the ADC8/TX24 speech level. Signed candidate `7.3.1-105` passed package admission and was written, synced and read back in slot A; accepted `102` remains in B. The new candidate has not yet completed its physical boot and microphone checks. See [the engineering record](docs/MICROPHONE-BRINGUP-20261030.md) and [branch boundaries](docs/BRANCHES.md).

Native display output, the Fedora KDE desktop and basic device operation have been demonstrated. VRR, external display features, sleep, charging protection and long-term stability still need further testing. For the current peripheral-by-peripheral status, see the [Uke Linux hardware table](https://github.com/MCC45TR/uke-linux#hardware-support).

The normal boot path currently enters **EL1**. EL2/KVM work is maintained separately and is not part of the validated Fedora boot path.

## Install on Fedora

Development RPMs are published to [COPR unstable](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/). For an existing unstable-family installation on Fedora Rawhide AArch64, use
DNF after the chosen candidate's source and delivery conditions are satisfied:

```bash
sudo dnf copr enable mcc45tr/uke-linux-unstable
sudo dnf update
```

The kernel, modules, device trees and boot image must use matching versions.
Automatic seamless staging stays enabled across DNF installs and updates.
Rollback mode is a separate persistent local preference: package defaults stay
rollback-enforced, and an existing rollback-off choice must survive upgrades
and reinstalls without reapplying its command. Keep the accepted kernel and
matching modules available. Initial migration between package families requires
a reviewed DNF transaction and recovery route.

### RPM packages

| Package | Purpose |
| --- | --- |
| `senemos-uke-linux-kernel-mainline-unstable` | Development kernel package set |
| `senemos-uke-linux-kernel-mainline-unstable-core` | ARM64 kernel image, configuration and metadata |
| `senemos-uke-linux-kernel-mainline-unstable-modules` | Matching kernel modules |
| `senemos-uke-linux-kernel-mainline-unstable-dtbs` | Uke device trees and display overlay |
| `senemos-uke-linux-kernel-mainline-unstable-boot` | Matched Android boot image and boot metadata |
| `senemos-uke-linux-kernel-mainline-unstable-singleboot` | Userdata profile and selected-image metadata |

## Build from source

```bash
git clone https://github.com/MCC45TR/senemos-uke-kernel-mainline.git
cd senemos-uke-kernel-mainline
```

Run compilation, source fixtures and RPM production only in COPR workers. Source-profile, patch, configuration and signature checks precede source-RPM generation. Main's current combined-source admission limit is documented in [BRANCHES.md](docs/BRANCHES.md); archived overlay workers reproduce their pinned trials and do not qualify the combined source.

The older `senemos.sh` build entry remains available for legacy and diagnostic workflows. It does not reproduce the current consolidated native boot image. See [BUILDING.md](docs/BUILDING.md) and the [native source profile](packaging/native/README.md) for prerequisites and supported build paths.

## Branches

| Branch | Purpose |
| --- | --- |
| [`main`](https://github.com/MCC45TR/senemos-uke-kernel-mainline/tree/main) | Integrated Linux 7.3 kernel and singleboot packages |
| [`kvm`](https://github.com/MCC45TR/senemos-uke-kernel-mainline/tree/kvm) | Isolated experimental EL2/KVM development |

Previous branch tips remain under `archive/` tags. Singleboot is a package profile, not a separate branch. Detailed development changes belong in [CHANGELOG.md](CHANGELOG.md).

## Documentation

- [Source manifest](manifests/linux-7.3.0.json) — upstream version, patches and checksums
- [Build guide](docs/BUILDING.md) — COPR builds and tooling
- [Native packaging](packaging/native/README.md) — source integration and package details
- [Architecture](docs/ARCHITECTURE.md) — kernel integration overview
- [Automation](docs/AUTOMATION.md) — source updates and COPR workflow
- [Reports](reports/) — technical findings and validation records

Bug reports should include the device, kernel version, steps to reproduce and relevant logs. Use [GitHub Issues](https://github.com/MCC45TR/senemos-uke-kernel-mainline/issues) for bugs and [SECURITY.md](SECURITY.md) for security reports.

## License

Project scripts and documentation are available under the [MIT License](LICENSE). Linux kernel code and derived patches retain their original licenses and SPDX notices.
