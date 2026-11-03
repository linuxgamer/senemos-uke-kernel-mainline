# Development branches

1 November 2026. `main` is the source integration branch and `kvm` retains the
isolated experimental EL2/KVM producer. These are the two retained branches.
The former `test` tip is already reachable from `main`. Source integration does
not establish package, VM or tablet acceptance.

## Preserved history

Before cleanup, all 119 remote branch tips were copied to lightweight tags under
`archive/consolidation-20261101/`, followed by each original branch name. Existing
archive tags and commit identities remain unchanged. The 102 historical
`archive/tablet-20261101/` branches are retained as tags rather than merged as
old source snapshots. They include superseded release compositions and
experimental variants that must not replace current source automatically.

The requested `c9335a8fdd20a7ee2a33ce203fb5c0e85a2fddb3` PM8010 record was already
an ancestor of `main`. The dated evidence remains limited to the recorded trial.
The exact `fcbdae4b757732f0f0e3162c610f19abae290832` release1006 source pin remains
reachable and unchanged. The `kvm` branch stays at
`7a8b75f1471a6c9e2e1b6dccdb24bcb20276780f`; its package identity and isolated
activation boundary are preserved.

The current non-archive topic histories are integrated into `main`: O82 native
color and default-off CABC, audio topology naming and lookup, startup warning
corrections, LMH policy-ready IRQ ownership, optional storage encryption, USB
role/PM serialization, and the isolated 1010 and maintenance producer records.
The older USB topic contributes ancestry while the newer serialized producer
already on main is retained. Main's watchdog, optional gaming, KVM helpers,
transactional updater requirements and source inventories remain present.

## Validation and release boundary

1 November 2026, Debian x86_64 host: the source-contract body of `make validate`
passes independently of release admission. O82 firmware-loader and register-DMA
fixtures pass with GCC and Clang ASan/UBSan; leak detection is disabled because
of the sandbox's ptrace restrictions. Audio ELD and storage prerequisite
negative controls pass. No upstream kernel compilation, package installation,
VM boot or tablet test is implied by these host checks.

Ordinary `make validate` and `make srpm` continue to refuse Linux 7.3.1 under
the inherited Linux 7.4-rcN channel admission. The combined source retains the
historical release106 metadata; this is not permission to rebuild or publish
that consumed identity. Allocate and verify a fresh release only as part of a
separately authorized build. No release is reserved by this consolidation.

Historical `packaging/native/copr-*.sh` recipes describe exact pinned-parent
trials. Use their archived commits for reproduction. Their fixed release
numbers, overlay inventories and producer checks do not qualify this combined
tree. COPR configuration, build requests, devices and installed policy are
outside this source-only cleanup.

Before future branch deletion, verify the exact tip against a fresh remote
snapshot, preserve it in an immutable archive tag, and establish either current
source integration or an explicit historical/experimental archival disposition.
Use exact-tip deletion leases; leave concurrently changed branches for a new
audit. Never force-update `main`, `kvm` or existing archive tags.
