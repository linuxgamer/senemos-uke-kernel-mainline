# Kernel source layout

The normal build uses the signed Linux 7.2.9 release source, the 44 patches in
`patches/7.2.9/series`, and the ARM64, Uke and Fedora config fragments in
`configs/`. `manifests/linux-7.2.9.json` pins the source, patch and config
identities. `build.sh` prepares the source and builds local RPMs in a pinned
container. Fedora 44 is the default build target; explicit `--release rawhide`
uses the earlier base images and separate work/artifact paths. The Fedora 44
recipe passed a full 7.2.9 build, package checks and emulated AArch64 RPM
lifecycle tests on 16 October 2026; no tablet boot was tested. Rootfs and boot
image migration remains separate. The experimental Linux 7.2.10 profile is separate.

`src/boot/` contains the stock bootloader device-tree adaptation. It is used
for a boot-specific image path and is not part of the ordinary 7.2.9 RPM patch
series. `src/display/` contains the native display candidate; it is not enabled
in the normal build. `tests/` contains host checks for individual contracts.

Keep reviewable changes in source, patches, configs and manifests. Keep
downloaded upstream archives and local firmware receipts under ignored `private/`, and generated files
under ignored build and artifact directories. Android 6.1 vendor modules cannot
be used as Linux 7.2 modules.

Source application, compilation, package tests and tablet operation are
different checks. In particular, a compiled device tree does not prove that
its hardware providers work on a tablet.
