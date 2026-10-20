# Senemos Uke Mainline Kernel

Mainline Linux kernel, device trees and Fedora packages for **POCO Pad X1** and **Xiaomi Pad 7** (`uke`, Qualcomm SM7675).

This is an **work in progress** ARM64 kernel project, not a ready-to-install stable release. Most published device results/tests come from **POCO Pad X1**, they should not be treated as verified Xiaomi Pad 7 results.

## Packages

The Fedora packages provide a matching kernel image, modules, device trees and Android boot container:

- `senemos-uke-linux-kernel-mainline` — package set
- `senemos-uke-linux-kernel-mainline-core` — kernel image
- `senemos-uke-linux-kernel-mainline-modules` — matching modules
- `senemos-uke-linux-kernel-mainline-dtbs` — device trees
- `senemos-uke-linux-kernel-mainline-boot` — boot container and metadata

Development packages are published through [COPR](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-test/). Installation and flashing are separate operations; installing an RPM does not automatically make a device safe to boot.

## Building

```sh
git clone https://github.com/linuxgamer/senemos-uke-kernel-mainline.git
cd senemos-uke-kernel-mainline
make validate
make srpm
```

See [BUILDING.md](docs/BUILDING.md) and the files under `docs/` for build profiles and test requirements. Legacy `senemos.sh` script does not reproduce the current packaged boot images and shouldnt be used.

## Important

Related projects: [Uke Fedora](https://github.com/linuxgamer/uke-fedora) · [Fedora image builder](https://github.com/linuxgamer/uke-fedora-builder) · [Hardware support](https://github.com/linuxgamer/uke-linux-hardware-support)

Project tooling is MIT-licensed; Linux sources and patches retain their upstream licenses.
