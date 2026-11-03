# Optional gaming and Windows runtime interfaces

30 October 2026. This candidate retains the exact Linux 7.3.0-54 hardware
source from COPR 11228863 and changes two kernel options to modules:
`CONFIG_NTSYNC=m` and `CONFIG_BINFMT_MISC=m`. It does not install or recommend
Wine, Proton, FEX, Gamescope, MangoHud or an upscaling SDK. It adds no module
autoload policy, executable registration or global graphics override.

NTSYNC supplies NT semaphore, mutex and event interfaces for a compatible
Wine/Proton runtime. `binfmt_misc` allows an optionally installed userspace
interpreter to register foreign executable formats. Neither replaces an
x86/x86-64 translator on this ARM64 device. The existing 4 KiB pages, futex,
namespaces, seccomp, shared memory and input interfaces are retained.

On the installed release-54 baseline, Mesa 26.2.6 reports fragment shading
rate and graphics pipeline library support, and both Freedreno and Zink are
present. SGSR 1/2 are application shaders; SGSR 2 also needs engine-provided
depth, motion and history. VRS needs renderer integration. MangoHud uses
existing graphics and telemetry interfaces. No additional kernel graphics
driver is needed solely for these features.

Install applications separately when wanted. After booting a matching kernel,
`modprobe ntsync` makes the optional NT device available; a compatible runtime
must actually use it. Interpreter registrations belong to the chosen emulator,
not this kernel package. No default `.exe` handler is registered here.

Remote config, native module architecture, vermagic and signatures are package
checks. A successful build does not establish Wine application compatibility,
SGSR pixel quality, VRS rendering correctness, HUD metrics or an FPS gain.
The current device kernel, matching rollback and explicit boot approval remain
separate from the staged candidate.

## Package validation receipt

COPR build [11232037](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11232037/)
succeeded for `fedora-rawhide-aarch64`, using source commit
`99a773f8d26e3059e8d1bbf15a68aeb5dc839a96`. Release `7.3.0-72.fc46` is
isolated in `uke-linux-unstable:custom:optional-gaming-20261030`; it is not
published into the ordinary update path. The existing project source definition
was not changed.

The native build verified all 823 module signatures and refused tampered,
unsigned and wrong-key controls. Downloaded binary RPMs passed signature and
digest verification with the project's single pinned key
`2204A661EA630A5303500085538797E72A3E4ECA`. Both new modules are AArch64 ELF,
have matching `7.3.0-72` vermagic and carry the build's kernel-module signature.
The SRPM is unsigned; its SHA256 digest is
`1687e7c6c4d9a1d8d0f21169c3751350d37337023f9e1d87aebea607418212e8`.

The on-device DNF preview resolves five parallel kernel packages and one
singleton metadata upgrade, with no old kernel removal or application install.
The release-49 umbrella predates its install-only provider; appending its
package name to `installonlypkgs` for this transaction preserves that version.
The global DNF configuration is unchanged.

No installation, boot write, module load or reboot has been performed for this
candidate. The installed updater's `automatic=1` setting makes the boot RPM's
post-transaction hook activate a boot bundle, so deployment awaits the user's
explicit boot/restart decision. Release-54 image digest checks passed; this
does not constitute a new physical rollback trial or release-72 acceptance.
