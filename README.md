# Uke mainline Linux kernel

Kernel source adaptations, device trees and RPM packaging for `uke`. This repository is the kernel component of
[uke-fedora](https://github.com/linuxgamer/uke-fedora).

The kernel builder defaults to Fedora 44, use
`--release rawhide` for Fedora Rawhide build.

## Build

Run the standalone builder from this directory:

```sh
./build.sh --build 7.2.9 --distro=fedora --dry-run
./build.sh --build 7.2.9 --distro=fedora --test
```

The first command shows the plan without installing packages or building. The
second may install host prerequisites, downloads the signed kernel source,
builds in a container and tests RPM installation in a disposable AArch64
environment. Local artifacts go to `artifacts/fedora-44/7.2.9/`, or
`artifacts/fedora-rawhide/7.2.9/`. See [building instructions](docs/BUILDING.md) before trying to build, especially for host requirements and offline builds. From the parent `uke-fedora` workspace `./build.sh kernel` can be used, followed by the same options.

`make validate` checks the pinned patch and config hashes. `make srpm` prepares
the source RPM from the signed upstream archive; it can download source files.

## Repository guide

- [Architecture](docs/ARCHITECTURE.md) explains the source and patch layout.
- UFS and USB host paths still need device work.
- [Linux 7.2.9 patches](patches/7.2.9/README.md) record patch scope and attribution.
- [Native display candidate](src/display/README.md) is separate from the normal boot build.
