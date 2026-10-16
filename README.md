# Uke mainline Linux kernel

Kernel source adaptations, device trees and RPM packaging for Xiaomi Pad 7 and
POCO Pad X1 (`uke`, Qualcomm SM7675). This repository is the kernel component of
[uke-fedora](https://github.com/linuxgamer/uke-fedora).

The implemented build target is Linux 7.2.9 for Fedora Rawhide AArch64. Fedora
44 is the planned stable target; this repository does not build it yet.

## Current status

The 15 October 2026 development installation booted Linux 7.2.9 revision 1.39
on a POCO Pad X1 from slot B into a Fedora Rawhide KDE desktop with Wi-Fi, SSH,
touch input and Adreno rendering. These results describe that tested
installation, not every build from this repository. Display output still uses
the firmware framebuffer through simpledrm. Native DPU/DSI, Bluetooth, audio,
USB host mode and suspend remain incomplete. See the [project hardware table](https://github.com/linuxgamer/uke-fedora#hardware-support)
for test scope and limitations.

Linux 7.2.10 and native display work are separate source candidates. A clean
build or host check does not establish that they work on the tablet.

## Build

Run the standalone builder from this directory. Bash is required; running
`./build.sh` without arguments displays help.

```sh
./build.sh --build 7.2.9 --distro=fedora --dry-run
./build.sh --build 7.2.9 --distro=fedora --test
```

The first command shows the plan without installing packages or building. The
second may install host prerequisites, downloads the signed kernel source,
builds in a container and tests RPM installation in a disposable AArch64
environment. Local artifacts go to `artifacts/fedora-rawhide/7.2.9/`. They are
unsigned development candidates; the builder does not flash a device or
select a boot slot. See [building instructions](docs/BUILDING.md) before running
it, especially for host requirements and offline builds. From the parent
`uke-fedora` workspace, use `./build.sh kernel` followed by the same options.

`make validate` checks the pinned patch and config hashes. `make srpm` prepares
the source RPM from the signed upstream archive; it can download source files.

## Repository guide

- [Architecture](docs/ARCHITECTURE.md) explains the source and patch layout.
- UFS and USB host paths still need device work.
- [Linux 7.2.9 patches](patches/7.2.9/README.md) record patch scope and attribution.
- [Native display candidate](src/display/README.md) is separate from the normal boot build.

Keep changes focused and record whether a result comes from source review, a
host build, package checks or a tablet test.
