# Kernel development architecture

Product name: `senemos-uke-linux-kernel-mainline`. The historical generic base
is Linux v7.2.8 at `9a66fdc0d7fd55f54235524a73435af99051e46f`. The reviewed
Uke source port targets Linux v7.2.9 at
`5fce161649b4d779d1b76d9fcd52dc77779774b8`, with eight subsystem patches and
separate ARM64, Uke and Fedora config fragments. This repository's standalone
`senemos.sh` entry builds the signed release source and records the resolved
config, source/patch/toolchain identities and module ABI. Active development
trees remain in `src/upstream/`; the earlier baseline is preserved.

Keep pristine-baseline, donor-6.12 and forward-port builds separate. Record the final development commit, config hash, toolchain digest, source time and exported patch tree identity. Store reviewable patches under `patches/`; never develop in `referances/`.

Port binding/TLMM, clocks, RPMh/regulators/GDSC, USB interconnect, scoped SMMU handoff, eUSB2/repeater, WCD939x and DWC3 in dependency order. Test generic infrastructure changes on non-target configs as well as Uke. Review retry behavior and resource lifetimes rather than accepting a successful compile as sufficient.

Stock-DTB transition profiles and standalone mainline DTS have separate checks. Preserve variant-specific reserved memory and framebuffer ownership. Android 6.1 vendor modules are not mainline 7.2 modules. Kernel code follows upstream C/assembly conventions; new companion device applications use C++.
