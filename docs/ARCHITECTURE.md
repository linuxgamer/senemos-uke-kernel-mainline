# Kernel source layout

The normal build uses signed Linux 7.2.9 release source, 44 patches in
`patches/7.2.9/series`, and ARM64, Uke and Fedora configs in
`configs/`. `manifests/linux-7.2.9.json` pins the source, patch and config
identities. `build.sh` prepares the source and builds local RPMs in a pinned
container. Fedora 44 is default build target; explicit `--release rawhide`
uses earlier base images and separate work/artifact paths.

The experimental Linux 7.2.10 profile is separate.

`src/boot/` contains stock device tree adaptation. `src/display/` contains native display work, its not enabled
in the normal build. `tests/` contains host checks.
