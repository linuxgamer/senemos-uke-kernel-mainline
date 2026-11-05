# O82 HDR tone-map source review

5 November 2026. The retained PB reference contains two `PostBlendHdrBlob`
records. Each has 17 x/y tone-map points and 33 panel-PCC coefficients. One
also carries adaptive tone-map, static-metadata, video-statistics and power
optimizer configuration. These are additional operations beyond input transfer,
gamut conversion and output gamma. The existing native generator keeps them
blocked; a PQ transfer curve alone does not implement either complete preset.

The exact reference is `Xiaomi-Pad-7-Development/android_vendor_xiaomi_uke`
at `6739c8ec275318a156aa3a65f04f54f8dad82926`, matching the previously admitted
PB input hash. Three small HDR libraries were acquired with exact size and Git
blob checks, then inspected statically. They are third-party-retained
proprietary OEM material; independent official-binary provenance and
redistribution permission are not established. No library or preset data is
included in this repository. [The source inventory](../manifests/o82-hdr-tonemap-review-20261105.json)
records exact paths, hashes, attribution limits and the comparison scope.

The retained color manager accepts the HDR XML blob; `libhdr_tm.so` supplies
`HdrImp::SetHdrBlob`, `HDRXml::LoadTmParams`, `HdrImp::DsppToneMap` and
`TMC::ToneMapping_3DLuts`. The latter's resolved calls include current-brightness
calculation, curve updates, forward/inverse HDR processing and gamut-only
paths. The DSPP wrapper bounds its three-channel result to 4,913 entries.
The static core converts RGB to XYZ, applies a separate luminance operation
and converts back. Its helper at `0x575f0` interpolates up to 17 logarithmic
knots in forward/inverse branches, with explicit binary32 arithmetic and
endpoint handling. Units, enum interpretation, matrix normalization, metadata
selection and full output quantization still need end-to-end derivation.
Symbol presence and these inspected paths do not establish their selection on
the running tablet. Actual AArch64 PLT/GOT relocations were resolved because
ordinary disassembler PLT labels misidentify calls in this binary.

In both reviewed PB records the 24 constant/nonlinear PCC coefficients outside
the nine linear terms are zero. This does not establish an identity matrix,
other-panel compatibility or permission to ignore those fields. A complete
converter must preserve the matrix, compose it with the client's CTM and
explicitly handle or reject unsupported terms. Raw knots and coefficients
remain private.

The Uke GPL driver remains authoritative for PCC4.0, IGC4.0 and gamut4.3
programming; the existing same-SoC comparison does not supply the proprietary
HDR policy. Current upstream `05441d697f7f9a927264f4058cbbc6a03dfcac9d` and
`msm-next` `d024361c631b3f020a26c07d683e5103404b0fbf` share the inspected DSPP
header, exposing PCC/GC callbacks without this XML tone-map algorithm. This
is a file-scoped comparison, not a claim about all upstream HDR support.

The next implementation requires a typed HDR input contract and independently
checked curve, matrix and metadata conversion, followed by integration with
the retained paired DSPP/atomic path and complete cumulative COPR checks.
Brightness/statistics lifecycle and physical optical/color acceptance remain
separate requirements. Initial selection, DMA admission and HDR advertisement
remain unchanged. This review builds no kernel and changes no target profile,
firmware, display output or boot selection.

## Typed luminance core qualification

The offline C++ luminance core now implements two to 17 typed logarithmic
knots, forward mapping and a left generalized inverse that preserves the
first input of internal and terminal output plateaus. It keeps separate
binary32 operations, source XYZ Y/10000 and panel-relative normalization,
endpoint/black handling and unchanged output on rejected inputs. XML/enum,
matrix, metadata/brightness/statistics and live DSPP integration remain open.
The production generator still refuses its unsupported HDR presets.

[COPR 11264550](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11264550/)
succeeded in 65 seconds at exact producer
`2730b7c287c6e19c91b4a890aba8ce6c42135233`. GCC and Clang each pass optimized
and ASan/UBSan runs: 341,032 integer IEEE754 comparisons, 24,582 independent
analytic luminance checks and 26 refusal cases per mode. The integer oracle
finds 22,972 cases where wider arithmetic changes the result. Both compilers
reject a controlled wrong-owner inverse at its required plateau assertion.
No private input or OEM code executes in these checks.

The independently verified trusted signed 10,097-byte RPM contains only three
text receipts and a license, with no scriptlets or executable payload. It
records the exact source/manifest and four actual compiler-mode results. The
[source manifest](../manifests/o82-hdr-curve-source-20261105.json) preserves
exact digests and the initial source-worker failure. This qualifies the typed
arithmetic core; complete native HDR output and physical optical acceptance
remain unproven.
