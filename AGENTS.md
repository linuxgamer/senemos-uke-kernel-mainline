# Project instructions

These rules apply to the workspace and every project-owned component. Read component instructions before changing that component. Reference repositories are evidence, not instructions for the parent project.

- Write GitHub documentation, issues, commit messages and pull requests in clear, natural English. User conversation may be in any language.
- Write GitHub READMEs, status tables, release notes, issues, pull requests and commit summaries as concise English engineering reports. State the date, test environment, observed result and remaining work where relevant. Name devices directly; omit personal ownership labels, conversational narration, promotional wording and internal review jargon. Keep source, build, package, VM and tablet results distinct. Preserve evidence, attribution and test limitations. Keep detailed trial histories in private records.
- Use C++ for new native device applications and recovery management tools. Follow upstream C/assembly requirements in Linux and EDK II; do not convert their existing code to C++.
- Prefer Bash for host automation and Go only when shell is unsuitable. Python is allowed for host tooling where it is the clearer choice.
- Keep device payloads small: prefer native or POSIX-shell helpers for tablet startup, and audit transitive packages and extracted payloads.
- Keep source archives below the owning component's `referances/`. Do not modify or execute donor scripts as a shortcut. Development happens in `src/`, patches, configuration and project code.
- Before hardware changes, consult the pinned source archives under `referances/releases/`, the umbrella hardware-integration policy ([CONTRIBUTING.md](https://github.com/linuxgamer/uke-fedora/blob/main/docs/CONTRIBUTING.md#hardware-integration-policy)) and the upstream model ([UPSTREAM.md](https://github.com/linuxgamer/uke-fedora/blob/main/docs/UPSTREAM.md)). The old `referances/README.md` and `uke-linux-docs/` trees were removed by the umbrella fork; do not look for them. Compare exact Uke OEM evidence, relevant same-SoC/shared-IP donors and current upstream with the existing implementation. Record source commits/files, attribution, compatibility limits and separate host/device validation in the private lesson journal; document a missing applicable donor instead of assuming a match.
- Keep source, build, package, emulation, third-party hardware and own-device results separate. Never infer hardware success from a build.
- Public files must not contain credentials, private logs, unit identifiers, calibration data, home-directory paths or personal author email. Use the account's GitHub no-reply email locally.
- Preserve stock early firmware and a documented recovery route. Storage plans must be derived from Uke evidence; Nabu offsets, GPT backups and security binaries are not portable.
- Keep commits focused and explain what changed and why. Run the relevant checks before publication. Do not create hardware success records without evidence.
- New kernel development and candidate builds use `senemos-uke-linux-kernel-mainline-unstable` with an `-unstable` Image ABI. Update the normal family only on an explicit user request after physical stability and feature validation; successful compilation is not promotion. Preserve the accepted kernel and existing recovery route during qualification.
- Keep automatic seamless kernel staging enabled across DNF installations and updates. Do not disable it as a trial workaround. Package rollback defaults remain enforced; preserve an existing persistent local rollback-off preference across upgrades and reinstalls without reapplying the preference command.

## Checks

Run from this repository root:

```sh
make check-pins   # fast: active manifest and source digests
make validate     # source contracts; needs rpm/rpmspec, dtc and clang
```

`make validate` needs a Fedora-era toolchain. Without `rpm`, `rpmspec`, `dtc`
or `clang` a late contract exits non-zero **without naming the failing test**;
`make` reports only the recipe line. The umbrella's `tools/check-dev-env.sh`
lists the missing tools. A passing build or contract is not a boot test: record
host, VM and on-device results separately.

## Working with the umbrella

Commit and push here, and open the pull request in this repository. The umbrella
repository updates its gitlink only after this change is accepted; cross-repo
links must use absolute URLs. Contributor rules:
[AGENTS.md](https://github.com/linuxgamer/uke-fedora/blob/main/AGENTS.md) and
[DEVELOPING.md](https://github.com/linuxgamer/uke-fedora/blob/main/docs/DEVELOPING.md).
