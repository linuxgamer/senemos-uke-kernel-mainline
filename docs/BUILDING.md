# Build the kernel

Run commands from the root of `uke-mainline-linux`. Builder defaults to Fedora 44, earlier
Fedora Rawhide build remains available through `--release rawhide`.

`./build.sh kernel` can be used from `uke-fedora` (parent) directory.

## Inspect the build

```sh
./build.sh --build 7.2.9 --distro=fedora --dry-run
./build.sh --build 7.2.9 --release rawhide --offline --dry-run
./build.sh --help
```

`--dry-run` resolves the target without installing packages, downloading
sources or compiling. A release selected with `--build latest` still needs a
reviewed version profile in `manifests/`

## Build local RPMs

```sh
./build.sh --build 7.2.9 --distro=fedora
```

The entry can install missing host prerequisites from the host
repositories. It needs a working Podman or Docker and at least
**25 GiB** of free space. Compilation runs in a Fedora 44 container. Use
`--jobs N` to set parallel jobs. The entry stores downloaded release archives
under `private/releases/`, reusable work under
`build/fedora-44/7.2.9/`, and results under
`artifacts/fedora-44/7.2.9/`. With `--release rawhide`, work and results use
`build/fedora-rawhide/7.2.9/` and `artifacts/fedora-rawhide/7.2.9/` instead.

Use `--offline` only after the signed source, release metadata and exact
toolchain image have been cached. An offline package test also needs the cached
AArch64 test runtime.

## Check packages

```sh
./build.sh --build 7.2.9 --distro=fedora --test
```

`--test` adds RPM install, upgrade and removal checks in a AArch64
environment for the selected Fedora release. On an x86_64 host, the entry may
need to install and register QEMU user emulation. The test checks packages and their target payload;

`make validate` checks the pinned patch and config hashes without compiling.
`make srpm` prepares only the source RPM, downloading and verifying the
upstream archive if it is absent. `./build.sh --self-test` runs host-only
contract checks.
