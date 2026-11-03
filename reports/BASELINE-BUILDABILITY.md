# Linux 7.2.8 arm64 baseline buildability

30 September 2026. The pinned Linux stable `v7.2.8` source at commit
`9a66fdc0d7fd55f54235524a73435af99051e46f` was cloned as a shallow
development checkout under `src/upstream/linux-7.2.8`. Its full history is
not claimed to be archived by this checkout.

With Android Clang 20.0.0 (`clang-r547379`), `ARCH=arm64`, `LLVM=1` and the
upstream `defconfig`, `make -j6 Image dtbs` completed successfully. The output
`Image` is 40,598,016 bytes, SHA-256
`5691fe5c19ea69328a3cf2990f2ccb05f7eac1ccb600a4c291e927c95183d8a4`.
The generated `.config` SHA-256 is
`0d9d79392c99b8ecbf2060bacfa18960d51c4d87d7637b76171e96d2fcd8bdf7`;
1,847 DTB files were generated. Full host logs remain private and ignored.

An initial `Image dtbs modules` invocation was deliberately stopped after
several minutes to focus on the requested buildability check. The successful
`Image dtbs` run reused the unchanged partial objects. A subsequent
`make -j6 modules` completed successfully on 30 September, generating **1,655**
AArch64 modules. `modules_install INSTALL_MOD_STRIP=1` also completed in an
ignored component-local staging root, with the `7.2.8` release directory and
dependency indexes generated. `Module.symvers` SHA-256 is
`8a0983259f8ed83f34ec1132b1ba940e3c9ab9771fe05c4e77b3d727d7107552`.
These generic modules must not be loaded into the stock 6.1 recovery kernel.
No Uke/SM7675 DTB was found in this
upstream tree, and no Uke-specific patch or configuration was built. This is
**generic upstream compile evidence only**, not a bootable Uke kernel, module
ABI validation, package result or physical-device test.
