# Source verification and publication

`make validate` checks the pinned patch and config hashes in
`manifests/linux-7.2.9.json`. `make srpm` downloads the matching Linux source if
needed, checks its SHA-256 hash and detached signature, then creates an SRPM.
`build.sh` provides the local container build and optional AArch64 RPM
installation test. See [BUILDING.md](BUILDING.md) for commands and limits.

The former COPR source-generation Makefile and daily GitHub workflow are absent
from this checkout. Updating the kernel does not currently trigger an automatic
COPR build here. The existing [development COPR](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-test/)
contains historical builds; publication through the linuxgamer account is
planned separately.

A new Linux version needs its own pinned source identity, reviewed Uke patches,
config and package checks. A successful local or COPR build does not prove a
tablet boot or working peripherals.
