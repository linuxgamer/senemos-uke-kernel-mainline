# Permanent GDSC provider storage

3 November 2026, Linux 7.3.1 source candidate. The existing resource owner
retains MMIO, interface clocks and regulators after uncertain or published
probe failures. It cannot retain the managed `genpd_onecell_data` and domain
array allocated by `gdsc_register()`. A later failure in the same probe could
leave the published OF provider pointing at freed memory.

The optional `gdsc_desc.permanent_data` path accepts caller-owned provider and
domain-array storage. The caller must retain both objects for the lifetime of
the permanent controller, including failed probe cleanup. It must initialize
the exact domain count and clear every slot before registration. Only domains
using the independently validated controller-PM contract are admitted; managed
parent attachments and regulator/ICC handles are excluded. Other callers keep
the original managed-allocation path. Failed registration clears initialized
slots after the existing genpd/parent unwind, while uncertain controller PM
references remain retained.

The fault fixture imports the actual complete patched GDSC source/header. It
checks both allocation paths, sparse topology, malformed descriptors, every
domain-init/link/publication failure, and provider lookup after simulated
managed-resource release. It also verifies that held controller PM references
survive errors and prevent unsafe retry. Run it normally and with fail-fast
ASan/UBSan on the COPR worker. These tests model registration/lifetime boundaries;
they do not qualify electrical power transitions or tablet capture.

This API is not connected to an active camera provider yet. The caller must
still supply permanent clock/reset/domain objects, connect all fault and PM
hooks, and qualify firmware handoff, shutdown, concurrency and the complete
capture graph before DT activation. No domain is opted in by this increment.
