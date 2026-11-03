# Source verification and automatic COPR builds

31 October 2026. Delivery uses [mcc45tr/uke-linux-unstable](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/) on Fedora Rawhide AArch64. Compilation, source fixtures, schema validation and RPM production run in COPR workers. Source and binary build logs retain separate results.

The current qualified-candidate workflow uses a custom source worker pinned to a complete Git commit and a checked parent SRPM. Official Fedora worker tools verify source hashes and signatures before producing the new source RPM. A fresh kernel release is required once an NVR has a published source package; rebuilding it would create another module key for the same installed ABI. Never bypass that admission guard.

`main` holds the combined continuation source. Its ordinary `.copr/Makefile` retains the reviewed-series admission limit described in [BRANCHES.md](BRANCHES.md). Historical native overlay workers reproduce their archived pinned trials. Their successful packages do not establish a complete-main build, and their overlay lists must be reconciled with the current source lock before reuse.

The GitHub workflow queries Kernel.org and COPR and retains an isolated `kvm` lane. It does not add an automatic main-push submission. COPR package source configuration and webhooks are separate settings; inspect their exact commit, producer and requested chroot before any release. Credentials and webhook secrets never belong in source or reports.

A new stable version needs its own `manifests/linux-VERSION.json`, signed source identity, Uke patches and config hashes. An unsupported stable release stops tracking with an explicit error. The workflow cannot silently replace the Uke port with generic ARM64 or reuse a different version's adaptation. After that version's reviewed profile and packaging version are committed, source generation downloads the matching stable archive automatically.

Publication can use the native HTTPS COPR API. Upstream RPM policy and dt-schema Python tools run only in the COPR build environment; they are not project tablet services or payloads. Project-owned tablet and recovery payloads exclude Python.

COPR's Fedora source-generation chroot and Rawhide repository packages can advance independently. Each job retains its source RPM, tool versions and build logs. Neither automation nor a successful package build proves Uke boot, firmware handoff or peripheral operation.

Each kernel packaging release has a distinct uname, module directory and
matched Image. Installonly retention preserves the accepted rollback tuple.
On singleboot userdata installations, the final DNF transaction stages and
verifies the selected kernel in the inactive Linux slot before selecting it.
The accepted slot and modules remain available; reboot timing belongs to the
administrator. Native identity, firmware, power and transaction checks apply.

References: [COPR source methods and webhooks](https://docs.copr.fedorainfracloud.org/user_documentation.html), [Kernel.org stable feed](https://www.kernel.org/releases.json).
