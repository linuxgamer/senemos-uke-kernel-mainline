# CAMCC controller-resource lifetime candidate

3 November 2026, Linux 7.3.1 source. This extends the inactive camera catalog and
power callback candidate from project revision
bd8475eda093723b540a14dc72b8c16770de30e0. It does not register a camera clock
provider or enable camera DT nodes.

Linux device-unbind cleanup releases devres, clears driver data/binding and
reinitializes runtime PM. Managed clock/regulator handles can therefore disappear
while the old controller retains voltage votes or a boot-ON GDSC reference.
A runtime-PM count or a device reference does not retain those handles.

The new owner holds explicit device, clock, optional regulator, MMIO reservation,
mapping and regmap references. Missing supplies cannot become dummy regulators.
Only the exact Uke MMIO window, static DT and a permanent built-in driver with
the supplied PM callbacks and no user unbind interface are admitted. Parallel
power-domain ownership is rejected; the existing regulator aggregator remains
the sole voltage path.

A clean, unpowered, unpublished failure releases acquired resources and permits
deferred probe to retry. A voltage uncertainty, outstanding clock/domain/child
reference, foreign class state or possible provider publication latches a fault
and retains resources. Probe failure, detach and shutdown keep the controller
state valid through core cleanup. Checked accesses stop on the latched fault.
There is no reset/retry API for quarantined hardware.

The native fault fixture imports the actual voltage aggregator, power callbacks
and forced-PM functions. The original managed-handle candidate must fail the
same retention assertion. Candidate cases cover every acquisition failure,
clean retry, live/boot-held/uncertain/published states, independent voltage
votes, wrong ownership and detach. A separate AArch64 object checks the complete
catalog and owner against the actual candidate kernel layout. It is not linked
into Image or installed.

[COPR build 11247646](https://copr.fedorainfracloud.org/coprs/build/11247646)
passes on Fedora Rawhide AArch64, 3 November 2026, with tested source
51b00abd9fb3d0eb4b7ea38ebf7e2f4d48edf904 and kernel ABI 7.3.1-1014.
The original managed-resource assertion fails with expected exit 134; the
candidate power/owner and 91-case GDSC fixtures pass normally and under ASan/UBSan.
The complete kernel compiles in 1,144 seconds with four jobs; the boot bundle
takes 1,219 seconds and retained package checks take 55 seconds. The owner object
is AArch64, Image is unchanged and the object is absent from the payload.
Six existing binary package names are emitted in the isolated side repository.
No binary delivery signature review, device installation or physical camera
test is claimed. ABI 1014 is reserved; changed inputs need a fresh ABI.

The GDSC prerequisite is compiled with its opt-in controller-PM flag. No domain
opts in. The qualified registration unwind is retained, with the existing
91-case registration fixture and separate transition/forced-PM checks.

This owner retains controller resources. It does not by itself retain arbitrary
devm clock/reset/provider allocations or qualify consumer publication. The
native clock driver must connect the failure/detach hooks, per-clock fault and
voltage operations, firmware/proxy handoff, registration/removal and shutdown
before activation. Regulator/MMIO boundaries are modeled; electrical recovery,
concurrency, exact camera graph and physical capture remain unqualified.
