/* SPDX-License-Identifier: GPL-2.0 */
/* MiCode uke-v-oss 5712080a4b0c0b1a879e6d145c601c649ddaddfd, cliffs7_data.
 * Copyright (c) 2017-2021, The Linux Foundation.
 * Copyright (c) 2022-2024, Qualcomm Innovation Center, Inc.
 * Native names MODPE/WRCACHE retain the OEM numeric use-case identities. */
static const struct llcc_slice_config expected_policy[] = {
	{LLCC_CPUSS,     1, 3200, 0, 0, 0x3FFF, 0x0, 0, 0x0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{LLCC_VIDSC0,    2,  128, 3, 1, 0x3FFF, 0x0, 0, 0x0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{LLCC_AUDIO,     6,  256, 1, 1, 0x3FFF, 0x0, 0, 0x0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{LLCC_MDMHPGRW, 25, 1024, 3, 0, 0x3FFF, 0x0, 0, 0x0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{LLCC_GPUHTW,   11,  256, 1, 1, 0x3FFF, 0x0, 0, 0x0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{LLCC_GPU,       9, 3200, 1, 0, 0x3FFF, 0x0, 0, 0x0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0},
	{LLCC_MMUHWT,   18,  512, 1, 1, 0x3FFF, 0x0, 0, 0x0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{LLCC_DISP,     16, 3584, 1, 1, 0x3FFF, 0x0, 2, 0x0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{LLCC_MDMHPFX,  24, 1024, 3, 1, 0x3FFF, 0x0, 0, 0x0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{LLCC_MDMPNG,   27,  256, 3, 1, 0x3FFF, 0x0, 0, 0x0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{LLCC_MODPE,   29,   64, 1, 1, 0x3C00, 0x0, 0, 0x0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0},
	{LLCC_WRCACHE,    31,  512, 1, 1, 0x3FFF, 0x0, 0, 0x0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{LLCC_CAMEXP0,   4,  256, 3, 1,    0xF, 0x0, 0, 0x0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{LLCC_CAMEXP1,   7, 1536, 2, 1, 0x3FF0, 0x0, 2, 0x0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{LLCC_LCPDARE,  30,  128, 3, 1, 0x3FFF, 0x0, 0, 0x0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0},
	{LLCC_AENPU,     3, 2048, 1, 1, 0x3FFF, 0x0, 2, 0x0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{LLCC_ISLAND1,  12, 2048, 7, 1,   0x0, 0xFF, 0, 0x0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
};
