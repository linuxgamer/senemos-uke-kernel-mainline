# Build the Uke kernel

Run commands from the root of `uke-mainline-linux`. The current implemented
target is Linux 7.2.9 for Fedora Rawhide AArch64. Fedora 44 is planned, but the
builder and pinned toolchain still target Rawhide.

Bash is required. The standalone `./build.sh` displays help when run without
arguments. From the parent `uke-fedora` workspace, use `./build.sh kernel`
followed by the same options.

## Inspect the build

```sh
./build.sh --build 7.2.9 --distro=fedora --dry-run
./build.sh --help
```

`--dry-run` resolves the target without installing packages, downloading
sources or compiling. A release selected with `--build latest` still needs a
reviewed version profile in `manifests/`; the newest upstream kernel is not
automatically a supported Uke build.

## Build local RPMs

```sh
./build.sh --build 7.2.9 --distro=fedora
```

The entry can install missing host prerequisites from the host distribution's
repositories. It needs a working Podman or Docker environment and at least
25 GiB of free space. Compilation runs in a pinned Fedora container. Use
`--jobs N` to set parallel jobs. The entry stores downloaded release archives
under `referances/releases/`, reusable work under
`build/fedora-rawhide/7.2.9/`, and results under
`artifacts/fedora-rawhide/7.2.9/`. These directories are ignored by Git.

The results include four RPMs, an SRPM, Image, Uke DTB, config and build
inventories. Local RPMs are unsigned development candidates. The builder
does not flash a tablet, write Android partitions or change boot selection.
Installing a kernel package also does not create a boot image.

Use `--offline` only after the signed source, release metadata and exact
toolchain image have been cached. An offline package test also needs the cached
AArch64 test runtime.

## Check packages

```sh
./build.sh --build 7.2.9 --distro=fedora --test
```

`--test` adds RPM install, upgrade and removal checks in a disposable AArch64
Rawhide environment. On an x86_64 host, the entry may need to install and
register QEMU user emulation. The test checks packages and their target payload;
it does not boot the tablet or qualify its hardware.

`make validate` checks the pinned patch and config hashes without compiling.
`make srpm` prepares only the source RPM, downloading and verifying the
upstream archive if it is absent. `./build.sh --self-test` runs host-only
contract checks. None of these commands establishes a tablet boot.
