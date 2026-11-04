# Guarded native Uke camera controller bring-up

4 November 2026. The controller producer retains parent1900, links the permanent
SM7675 CAMCC driver into the actual kernel and enables its boot FDT conversion.
This is a hardware bring-up candidate. Both full cameras, fitted read-only
EEPROM calibration, rear focus, processing, modes and recovery remain required.

Fresh ABI2000 or later preserves successful parent1900's complete supplier,
display REGDMA, adaptive L3, SSC temperature, NFC/IR, secure RTC and earlier
source/boot changes. Earlier1702 passes the synthetic FDT and real standalone
object checks, then stops at the supplier scope gate before a full kernel build.
The updated scope admits only the reviewed built-in controller. Source2000 also
establishes transport gates before CRM access; no older qualification cohort
should be installed as a substitute for the latest accepted/staged baseline.

The boot converter validates the exact controller resource, clock-list shape
and provider argument widths before mutation. It reorders iface/XO/XO-AO/sleep,
adds the exact named CRM resource and power-domain cell declaration, and uses
the native compatible without the inherited syscon/CRM clock properties. It
rejects unknown camera-clock consumers. Known OEM camera, RSC/CRM and debug
consumers stay disabled while their native graph is implemented. The RSC/CRM
requests for clock71 cannot be satisfied by the current native catalog. Node
disabling changes the Linux graph; it does not stop firmware hardware.

The controller probe first enables and checks the four OEM always-on transport
gates. It checks the DRV_AHB gate at0x13318 before reading CRM mode while powered,
then admits the CRM-managed PLL/RCG/branch tree. Enabled CRM refuses the direct path
and retains resources in quarantine. A real active-CRM result requires the
matched vote/LUT/IRQ implementation before capture can proceed. Disabled CRM,
supplier admission and successful clock publication still need device evidence.

The FDT helper runs inside the existing private output transform only when
CONFIG_SM_CAMCC_7675 is enabled. Its ordinary/sanitized fixture exercises actual
helper code with a synthetic graph: clock permutation, CRM resource, known
consumer containment, unrelated data preservation, idempotence and refusals
before mutation. It does not qualify a complete live bootloader FDT. The known
paths were compared with exact Cliffs/Uke source and local read-only OF state;
no unit FDT or calibration bytes enter COPR. Existing host transform tests do
not enable the new kernel configuration; the helper fixture and actual kernel
object/link checks qualify the new path separately.

COPR must check both real native controller variants, complete CAMSS linkage,
the full kernel, actual builtin inventory/vmlinux driver and signed modules.
Packaged compile-stage DTBs remain distinct from the runtime bootloader FDT;
absence of a compatible in those DTBs alone does not prove runtime inactivity.
Recheck running/accepted/staged state and recovery before DNF delivery. No source
or worker success is a physical camera, calibration, focus or recovery receipt.
