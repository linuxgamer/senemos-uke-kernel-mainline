/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <linux/unaligned.h>
#include "../src/input/nt36532-uke-matrix.h"

static struct nvt_uke_matrix matrix;
static u8 data[NVT_UKE_NODES * 2];
static struct nvt_uke_frame frame = { .matrix_le = data, .scan_mode = 4 };
static struct nvt_uke_contacts contacts;

static void flat(unsigned int value)
{
	for (unsigned int i = 0; i < NVT_UKE_NODES; i++)
		put_unaligned_le16((u16)value, data + i * 2);
}

static void finger(unsigned int row, unsigned int column)
{
	for (int dy = -1; dy <= 1; dy++)
		for (int dx = -1; dx <= 1; dx++) {
			int y = (int)row + dy, x = (int)column + dx;
			if (x < 0 || x >= 60 || y < 0 || y >= 40)
				continue;
			put_unaligned_le16((u16)(10000 + (dx || dy ? 300 : 650)), data + (y * 60 + x) * 2);
		}
}

static void weak_finger(unsigned int row, unsigned int column, unsigned int peak)
{
	assert(row > 0 && row < 39 && column > 0 && column < 59);
	for (int dy = -1; dy <= 1; dy++)
		for (int dx = -1; dx <= 1; dx++) {
			unsigned int node = (unsigned int)((int)row + dy) * 60 + (unsigned int)((int)column + dx);
			put_unaligned_le16((u16)(10000 + (dx || dy ? peak / 2 : peak)), data + node * 2);
		}
}

static void process(void)
{
	assert(!nvt_uke_matrix_process(&matrix, &frame, 31999, 21359, &contacts));
}

static void initialize(void)
{
	memset(&matrix, 0, sizeof(matrix));
	for (unsigned int i = 0; i < 60; i++) matrix.columns[i] = 270 + i * 530;
	for (unsigned int i = 0; i < 40; i++) matrix.rows[i] = 270 + i * 530;
	flat(10000);
	for (unsigned int i = 0; i < NVT_UKE_CALIBRATION_FRAMES; i++) {
		process(); assert(!contacts.active);
	}
}

int main(int argc, char **argv)
{
	initialize();process();assert(!contacts.active);
	finger(20, 30);process();assert(contacts.active == 1);
	assert(contacts.x[0] > 15000 && contacts.x[0] < 18000);
	/* Interior OEM electrode coordinates must not be stretched to reach the edges. */
	assert(contacts.x[0] == matrix.columns[30] && contacts.y[0] == matrix.rows[20]);
	for (unsigned int i = 0; i < 2000; i++) {
		frame.scan_mode = i & 1 ? 2 : 4;
		process(); assert(contacts.active == 1);
	}
	finger(20, 35);process();assert(contacts.active == 3);
	/* A held, light contact must reach the MT slot hysteresis unchanged. */
	flat(10000);
	put_unaligned_le16(10090, data + (20 * 60 + 30) * 2);
	put_unaligned_le16(10050, data + (20 * 60 + 31) * 2);
	process();assert(contacts.active == 1 && contacts.peak[0] == 90);
	put_unaligned_le16(10069, data + (20 * 60 + 30) * 2);
	process();assert(!contacts.active);
	flat(10000);finger(20, 35);process();assert(contacts.active == 1);
	flat(10000);process();assert(!contacts.active);
	for (unsigned int i = 0; i < 10; i++) finger(4 + (i / 5) * 25, 4 + (i % 5) * 11);
	process();assert(contacts.active == 0x3ff);
	flat(10000);
	for (unsigned int i = 0; i < 10; i++)
		weak_finger(4 + (i / 5) * 25, 4 + (i % 5) * 11, 105 + i * 10);
	for (unsigned int held = 0; held < 2000; held++) {
		process();assert(contacts.active == 0x3ff);
	}
	flat(10000);
	for (unsigned int i = 0; i < NVT_UKE_NODES; i++)
		put_unaligned_le16((u16)(10000 + i % 45), data + i * 2);
	process();assert(!contacts.active);
	flat(10000);finger(0, 0);process();assert(contacts.active == 1);
	assert(contacts.x[0] < 1000 && contacts.y[0] < 1000);
	flat(10000);finger(39, 59);process();assert(contacts.active == 1);
	assert(contacts.x[0] > 31000 && contacts.y[0] > 20300);
	flat(10000);put_unaligned_le16(32767, data);process();assert(!contacts.active);
	for (unsigned int i = 0; i < NVT_UKE_NODES; i++) put_unaligned_le16((u16)(10000 + (i % 101)), data + i * 2);
	process();assert(!contacts.active);
	flat(11000);process();assert(!contacts.active); /* broad contact/palm */
	frame.scan_mode = 0;
	assert(nvt_uke_matrix_process(&matrix, &frame, 31999, 21359, &contacts) == -EINVAL);
	frame.scan_mode = 4;matrix.columns[1] = matrix.columns[0];
	assert(nvt_uke_matrix_process(&matrix, &frame, 31999, 21359, &contacts) == -EINVAL);
	initialize();nvt_uke_matrix_reset(&matrix);assert(!matrix.samples && matrix.columns[1] == 800);
	for (int argument = 1; argument < argc; argument++) {
		FILE *file = fopen(argv[argument], "rb");assert(file);
		u8 packet[NVT_UKE_FRAME_SIZE];
		unsigned int packets = 0, valid = 0, active = 0, maximum = 0;
		initialize();nvt_uke_matrix_reset(&matrix);
		size_t received;
		while ((received = fread(packet, 1, sizeof(packet), file)) == sizeof(packet)) {
			struct nvt_uke_frame decoded;
			packets++;
			if (nvt_uke_decode(packet, sizeof(packet), &decoded))continue;
			valid++;
			assert(!nvt_uke_matrix_process(&matrix, &decoded, 31999, 21359, &contacts));
			unsigned int count = (unsigned int)__builtin_popcount(contacts.active);
			if (count)active++;
			if (count > maximum)maximum = count;
			for (unsigned int i = 0; i < count; i++)assert(contacts.x[i] <= 31999 && contacts.y[i] <= 21359);
		}
		assert(!received && !ferror(file));fclose(file);
		printf("Private replay: packets=%u valid=%u contact_frames=%u maximum_contacts=%u; not physical input acceptance\n", packets, valid, active, maximum);
	}
	puts("Matrix: startup baseline, ten fingers, adjacent peaks, independent lifts, held contacts across scan modes, corners, noise/palm and invalid metadata: PASS");
}
