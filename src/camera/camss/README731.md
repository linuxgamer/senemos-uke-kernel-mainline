# Native SM7675 CAMSS and Uke CSIPHY 2.2.1

3 November 2026. The initial PHY producer qualifies an unlinked D-PHY helper.
The CAMSS producer then adds a distinct SM7675 resource profile and connects
that helper to the actual native CAMSS module. It retains the sensor/controller
prerequisites and full kernel/package checks. The packaged DT has neither new
camera compatible. No candidate installation, provider binding or physical
capture is established by these source changes.

The profile has five PHYs, three full and two lite CSID/VFE paths. Exact Cliffs
OEM source explicitly shares the full860 CSID/VFE bus/RDI/IRQ layouts with880;
stable native gen3 operations provide the corresponding RAW path. Uke PHYs use
the same L2B/L4B supplies,98480/17920uA loads and400MHz timers. Core rates come
from the OEM tables. The3GB/s HF instantaneous-bandwidth floor comes from OEM
CPAS; the AHB vote follows the shared native profile. These are source inputs,
not measured throughput or a full active interconnect/SMMU/DT contract.

PHY setup now returns an error to the actual stream caller. Empty lane masks
are rejected before changing a legacy clock mux; existing PHY callbacks retain
their successful return. The new bridge checks noncombo lane numbering and
propagates timing refusal. Normal/sanitized actual-caller tests qualify errors
and retained mux behavior. Package checks require the actual new module alias,
matching vermagic/nonempty signer and absence of camera activation in every
packaged DTB. The new controller remains unlinked in this producer.

The 103-entry table retains the exact Uke OEM order, values, delay units and
Qualcomm GPL-2.0-only attribution. Common control0x101c uses0x7a; reset stays
asserted until mission programming completes and exits to2 for noncombo D-PHY.
Disabling skew calibration writes zero to the16 named registers, as the OEM
code does. The stable generic callback skips them instead; substituting this
table alone would preserve different values after the initial reset sequence.
Native frame completion uses CSID, so this helper keeps all11 PHY IRQ masks
zero instead of adopting OEM interrupt enables.

The helper validates lane positions/duplicates, clock rate and settle arithmetic
before MMIO. It admits a400MHz timer and positive link frequencies up to750MHz
with an encodable settle count. This source range includes the reviewed stable
OV08D10 360/720MHz and OV13B10 560MHz candidates; fitted topology, all actual
modes and electrical timing remain unqualified. C-PHY, combo mode and additional
profiles remain outside this helper; the full camera goal is unchanged.

The caller must establish exclusive powered PHY/IRQ/clock/rail ownership and
propagate admission errors before using this helper. The native caller is
connected by the CAMSS producer; real ownership still needs the matched DT and
hardware qualification. Its raw MMIO/time interface does not detect electrical
failures or establish safe DMA, concurrent graph use or power teardown. Existing
source clocks and a passed object/fixture are not physical camera acceptance.

Source: MiCode/vendor_qcom_opensource_camera-kernel at
699fa15a98abd40fbb94f3a6fc00f91723d29d35,
`drivers/cam_sensor_module/cam_csiphy/include/cam_csiphy_2_2_1_hwreg.h`
SHA-2565d5bc215b97bdec610ec4698c49a297c0ccdfab211fb4c3380b8555ef63ca99a,
and `cam_csiphy_core.c`
SHA-25611f6a85cfb70ca7edbbe3a41c395fbe525c1db822f881171c527de652de78cb9.
The ordinary/sanitized differential fixture imports the independent pinned OEM
arrays and actual common/lane programming bodies, with MMIO/time modeled.
It compares512 lane-order/rate/skew cases plus invalid/timing refusals. A real
stable generic callback is the zero-skew negative comparison. The stable7.3.1
native source/settle helper is pinned independently. Neither donor scripts nor
Android libraries execute; no private profile or calibration bytes enter COPR.

The oracle imports parameter bit masks and the exact register-entry type from
the same pinned `cam_csiphy_dev.h` (SHA-256
efef1af717f54ad458a1db00c989fcaa4fdd775a8572d49ea8924cfad0ccee82).
Its `OEM_CSIPHY_` names keep those masks separate from native CAMSS enum values.
Native candidate tags are translated by semantic name; OEM numeric masks are
not substituted into the native callback contract. Initial1208 stops before
kernel compilation on a missing combo-tag fixture definition; no new PHY test
pass or device result is claimed for that build.

Corrected1209 imports the independent original masks/type and passes the512-case
ordinary/sanitized helper comparison and complete-source AArch64 object gate.
Its full-kernel result is recorded separately. The CAMSS integration adds source
and caller/module qualification after that checkpoint; do not transfer the
helper result to the complete new profile or physical cameras.

The earlier1209/1210 qualification producers retain parent1011. The current
CAMSS producer starts at fresh ABI2000 and retains successful COPR11252138 /
sourceaec8163 / parent1900. It preserves the complete supplier/REGDMA updates,
adaptive L3, SSC temperature, NFC/IR, secure RTC, SSC/IIO, Binder, touch, MEMLAT,
display and audio source/boot
recipe. Both profile and manifest-verified boot configurations enable the
sensor modules and record the updated config digest. Pinned RPM header/payload
digests and full remote RPM verification protect the retained source. New
source execution/packaging remains pending until its own COPR result.

The still-unlinked CAMCC object also has an exclusive read-only CRM mode guard;
enabled CRM refuses direct clock programming before publication. Camera DT
remains inactive. Actual delivery must recheck and preserve the latest accepted
source, independent changes and recovery route; no old qualification cohort
should replace a newer running/accepted baseline.
