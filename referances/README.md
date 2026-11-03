# Reference archive

The [14 October 2026 research inventory](../manifests/research-donors-20261014.json)
maps local donor checkouts to exact revisions, purpose and verification limits.
It supplements the archival catalog and does not change an active build lock.
The [15 October MiCode catalogue](../manifests/research-micode-20261015.json)
screens all 80 public repositories, verifies the existing Uke pins and records
complete NT36532/AIS source acquisitions. A shared controller is not a board
match; source acquisition does not establish native display, input or camera
support. Consult its linked private survey before selecting these sources.
Before a hardware fix, follow the workspace's
`uke-linux-docs/docs/DONOR-POLICY.md`: compare Uke OEM, the applicable same-SoC or
shared-IP donor and current upstream; record source files, attribution and Uke
compatibility limits in the private lesson journal.

This directory holds unchanged upstream clones and offline Git bundles. Large sources and private inputs remain local and are excluded from this repository.

The workspace catalog `manifests/sources.yaml` assigns each reference to one component. `manifests/sources.lock.json` records commit/tree identities, full-history verification, bundle checksums, offline restoration and missing dependencies. Run the workspace `scripts/sources.sh report` for current coverage.

A successful Git restore does not include missing submodule or LFS objects, prove a build, grant redistribution rights, or establish device support. Develop outside this directory. Never run archived partitioning or flashing scripts on a device.
