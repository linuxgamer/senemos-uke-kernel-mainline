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

The 7300-based color trial `7.3.1-10000-unstable` passed
[COPR 11260145](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11260145/),
including Image, linked/signed modules, both supplier DTs and boot/RPM checks.
Delivery is held: 8101 was installed and selected independently during this
build and adds a CAMCC boot stage absent from the color trial. Preserve that
isolated boot trial and review cumulative source before another color build.
The tablet still runs 7200; physical boot, full peripheral and color/HDR
acceptance remain open.

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
Unstable RPMs contain no activation scriptlets. Installed boot policy and
selection remain separate state and must be rechecked before a transaction;
the local automatic policy was enabled independently during this trial. Keep the accepted kernel and
its matching modules available. Initial migration between package families
requires a reviewed DNF transaction and recovery route.

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
