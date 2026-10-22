# Kernel repository layout

- `manifests/linux-7.2.11.json` pins the current source archive, patches and
  configuration hashes. Older version manifests remain because upstream still
  maintains their patch series.
- `patches/7.2.11/` and `configs/` are the reviewed Uke changes.
- `src/` contains device support and boot packaging helpers.
- `packaging/` contains the Fedora kernel RPM spec and native profile.
- `source-cache/` holds downloaded archives outside Git; `build/` holds local
  RPM and compilation output.

`make validate` checks the patch list and hashes. `make srpm` additionally
verifies the signed upstream source and creates a source RPM. The parent
Fedora 44 image builder compiles the matching kernel and assembles the
`boot_a`/`userdata` pair. Source and host checks do not prove tablet boot.
