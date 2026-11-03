/* SPDX-License-Identifier: GPL-2.0-only */
/* Qualcomm ABI: edk2-platforms 1c500d13, KodiakHelper.S/.h
 * (Qualcomm Technologies, BSD-2-Clause-Patent), and Aswin Murugan's
 * U-Boot v5 1/3, 2026-10-13 (GPL-2.0-only). Uke support is unqualified.
 */

	.section ".idmap.text", "ax"
	.balign 4
	.global uke_el2_primary_entry
	.type uke_el2_primary_entry, %function
uke_el2_primary_entry:
	/* No stack, MMIO or memory access before the ownership transition. */
	mov	x19, x0
	mov	x20, x30
	mrs	x21, MPIDR_EL1
	mov	x22, #1
	mov	x23, xzr
	mov	x24, xzr
	mrs	x9, CurrentEL
	cmp	x9, #8
	b.eq	.Lverify_el2
	cmp	x9, #4
	b.ne	.Lbad_el
#ifdef CONFIG_QCOM_UKE_GUNYAH_EXIT
	cbz	x19, .Lbad_args
	tst	x19, #7
	b.ne	.Lbad_args
	orr	x9, x1, x2
	orr	x9, x9, x3
	cbnz	x9, .Lbad_args
	mrs	x9, DAIF
	and	x9, x9, #0x3c0
	cmp	x9, #0x3c0
	b.ne	.Lbad_args
	mrs	x9, SCTLR_EL1
	tst	x9, #1
	b.ne	.Lbad_mmu
	tst	x9, #4
	b.ne	.Lbad_mmu
	movz	w0, #0x0121
	movk	w0, #0x0200, lsl #16
	mov	w1, #0x23
	mov	w2, wzr
	mov	w3, wzr
	mov	w4, #1
	mov	x22, #2
	dsb	sy
#ifdef UKE_EL2_TEST_RETURN
	/* Test only: a firmware error that returns without changing EL. */
	mov	x0, #-1
#else
	smc	#0
#endif
	mov	x23, x0
	mov	x24, #1
	mov	x22, #3
	isb
	/* A returned status alone does not establish EL2 or released stage-2. */
	mrs	x9, CurrentEL
	cmp	x9, #8
	b.ne	.Lno_transfer
	b	.Lverify_el2
#else
	b	.Lbad_el
#endif
.Lverify_el2:
	mov	x22, #4
	mrs	x9, SCTLR_EL2
	tst	x9, #1
	b.ne	.Lbad_mmu
	tst	x9, #4
	b.ne	.Lbad_mmu
	mrs	x9, HCR_EL2
	tst	x9, #1
	b.ne	.Lstage2
	mov	x0, x19
	mov	x1, xzr
	mov	x2, xzr
	mov	x3, xzr
	ret	x20
	.size uke_el2_primary_entry, . - uke_el2_primary_entry

	.global uke_el2_secondary_entry
	.type uke_el2_secondary_entry, %function
uke_el2_secondary_entry:
	/* PSCI must already return every secondary at EL2; never repeat the SMC. */
	mov	x19, x0
	mov	x20, x30
	mrs	x21, MPIDR_EL1
	mov	x22, #1
	mov	x23, xzr
	mov	x24, xzr
	mrs	x9, CurrentEL
	cmp	x9, #8
	b.ne	.Lsecondary
	b	.Lverify_el2
	.size uke_el2_secondary_entry, . - uke_el2_secondary_entry

.Lbad_el:
	mov	x0, #1
	b	uke_el2_refused
.Lbad_args:
	mov	x0, #2
	b	uke_el2_refused
.Lbad_mmu:
	mov	x0, #3
	b	uke_el2_refused
.Lno_transfer:
	mov	x0, #4
	b	uke_el2_refused
.Lstage2:
	mov	x0, #5
	b	uke_el2_refused
.Lsecondary:
	mov	x0, #6
	.global uke_el2_refused
	.type uke_el2_refused, %function
uke_el2_refused:
#ifdef UKE_EL2_TEST
	b	uke_el2_test_refused
#endif
	/* Debugger only: x0=reason, x9=register, x21=MPIDR, x22=stage,
	 * x23=raw SMC x0, x24=SMC returned. No unqualified memory/UART. */
	msr	DAIFSet, #0xf
1:
	wfe
	b	1b
	.size uke_el2_refused, . - uke_el2_refused
