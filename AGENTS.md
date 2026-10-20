# Contributor and agent instructions

- Keep changes focused on the kernel, device trees, patches, packaging or related build tools. Read component documentation before editing.
- Write public documentation and commit messages in English. Keep it casual and human-readable. Distinguish source changes, build results and physical device tests, never claim hardware support without evidence.
- Preserve exact device and firmware scope. POCO Pad X1 results do not automatically apply to Xiaomi Pad 7.
- Maintain matching kernel images, modules, DTBs and boot containers. Never change partitions, boot slots, OEM firmware or calibration data without a verified recovery plan and explicit scope.
- Keep donor source archives under `private/`; make changes in maintained source, patches and configs. Check upstream provenance and preserve licensing and attribution.
- Follow upstream C and assembly conventions for Linux. Prefer Bash for host automation. Document any unavoidable host-only build dependency.
- Keep credentials, private logs, serial numbers, calibration data and personal paths out of public files.
- Run relevant validation before committing (`make validate` where applicable). Describe what was tested and what remains untested.
