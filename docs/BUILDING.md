# Build the Uke kernel

The release image builder in the parent `uke-fedora` workspace builds the
matching kernel automatically. If you only need the kernel source RPM, run:

```sh
cd senemos-uke-kernel
make validate
make srpm
```

The current Fedora 44 release uses Linux 7.2.11. `make srpm` verifies the
kernel.org source checksum and signature, then packages the reviewed patches
and configuration. Its downloaded source archive stays in the ignored
`source-cache/releases/` directory. The SRPM appears in `build/srpm/`.

For complete TTY, KDE or GNOME boot and userdata image pairs, use the
[workspace image builder](../../uke-fedora-builder/README.md) instead. On an
x86_64 computer, `--cross-kernel` shortens the kernel build by using native
Clang. The image builder reuses completed kernel RPMs when their inputs match.

A successful package build does not establish that the tablet boots or that
its hardware works. The builder never flashes the device.
