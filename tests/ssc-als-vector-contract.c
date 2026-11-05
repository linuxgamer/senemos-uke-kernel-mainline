// SPDX-License-Identifier: GPL-2.0-only
/* Synthetic packets only; included after the existing actual-callback fixture. */
static struct fixture_bytes als_payload(unsigned int count, bool packed,
				       unsigned int status, int bad, u32 bits)
{
	struct fixture_bytes b = {}, values = {};

	for (unsigned int i = 0; i < count; i++) {
		u32 value = (int)i == bad ? bits : i ? 0x3f800000U : 0x41200000U;

		if (!packed)
			put_le(&b, 13, 1);
		put_le(packed ? &values : &b, value, 4);
	}
	if (packed)
		put_field(&b, 1, values.data, values.size);
	put_le(&b, 16, 1);
	put_le(&b, status, 1);
	return b;
}

static void als_vectors(void)
{
	struct ssc_controller c;
	unsigned int checks = 0;

	for (unsigned int shape = 0; shape <= 17; shape++) {
		for (unsigned int packed = 0; packed < 2; packed++) {
			for (unsigned int identity = 0; identity < 4; identity++) {
				struct fixture_bytes b = als_payload(shape, packed, 3, -1, 0);
				struct uke_ssc_event e = { .message = 1025, .ticks = 200,
					.payload = { b.data, b.size } };
				s64 value[3] = { 77, 88, 99 };
				struct ssc_sensor *s;
				bool accepted = shape == 2 || (!identity && shape == 6);
				int ret;

				setup(&c);
				s = &c.sensor[identity == 3 ? 4 : 3];
				strcpy(s->attributes.name, identity == 1 ? "synthetic-als" :
				       identity == 2 ? "stk_stk3bcx-extra" : "stk_stk3bcx");
				ret = ssc_sample_values(s, &e, value);
				assert((ret == 0) == accepted);
				if (accepted)
					assert(value[0] == 10000000 && value[1] == 88 && value[2] == 99);
				checks++;
			}
		}
	}
	for (unsigned int packed = 0; packed < 2; packed++) {
		for (unsigned int channel = 0; channel < 6; channel++) {
			for (unsigned int kind = 0; kind < 3; kind++) {
				static const u32 nonfinite[] = { 0x7fc00000, 0x7f800000, 0xff800000 };
				struct fixture_bytes b = als_payload(6, packed, 3, channel, nonfinite[kind]);
				struct uke_ssc_event e = { .message = 1025, .ticks = 200,
					.payload = { b.data, b.size } };
				s64 value[3] = {};

				setup(&c);
				strcpy(c.sensor[3].attributes.name, "stk_stk3bcx");
				assert(ssc_sample_values(&c.sensor[3], &e, value) == -EBADMSG);
				checks++;
			}
		}
		for (unsigned int fault = 0; fault < 3; fault++) {
			struct fixture_bytes b = als_payload(6, packed, fault == 0 ? 0 : 3,
				fault == 1 ? 0 : -1, 0xbf800000);
			struct uke_ssc_event e = { .message = fault == 2 ? 1024 : 1025,
				.ticks = 200, .payload = { b.data, b.size } };
			s64 value[3] = {};

			setup(&c);
			strcpy(c.sensor[3].attributes.name, "stk_stk3bcx");
			assert(ssc_sample_values(&c.sensor[3], &e, value) ==
			       (fault == 0 ? -EAGAIN : fault == 1 ? -ERANGE : -ENOMSG));
			checks++;
		}
	}
	printf("Actual STK3BCx ALS decoder: %u exact identity/shape, packed/unpacked, finite/status/unit refusal checks passed\n", checks);
}

static void als_vector_reports(void)
{
	unsigned int checks = 0;

	for (unsigned int id = SSC_QMI_REPORT_SMALL; id <= SSC_QMI_REPORT_LARGE; id++) {
		for (unsigned int packed = 0; packed < 2; packed++) {
			struct ssc_controller c;
			struct fixture_bytes b = als_payload(6, packed, 3, -1, 0);
			struct fixture_bytes attrs = {};
			static const u8 yes[] = { 40, 1 };
			static const u8 onchange[] = { 33, 1, 0, 0, 0, 0, 0, 0, 0 };
			static const u8 rate[] = { 29, 0, 0, 0xa0, 0x40 };
			struct ssc_sensor *s;
			struct ssc_qmi_response response = { .result_valid = 1,
				.client_valid = 1, .client = 0x123456789ULL };
			struct qmi_txn txn = { .id = 17 };

			setup(&c);
			c.client_known = true;
			c.client_id = response.client;
			fixture.early_report_id = id;
			s = &c.sensor[3];
			s->declared = true;
			s->ready = false;
			string_attribute(&attrs, 0, "stk_stk3bcx");
			string_attribute(&attrs, 2, "ambient_light");
			string_attribute(&attrs, 5, "sns_ambient_light.proto");
			attribute(&attrs, 3, yes, sizeof(yes));
			attribute(&attrs, 21, yes, sizeof(yes));
			attribute(&attrs, 16, onchange, sizeof(onchange));
			attribute(&attrs, 6, rate, sizeof(rate));
			recovery_event(&c, s, 128, attrs.data, attrs.size);
			assert(s->ready && !s->error && !strcmp(s->attributes.name, "stk_stk3bcx"));
			s->declared = s->registered = s->buffered = true;
			s->stream_active = false;
			c.pending = true;
			c.pending_id = txn.id;
			c.pending_sensor = s;
			c.pending_command = UKE_SSC_ON_CHANGE;
			recovery_event(&c, s, 1025, b.data, b.size);
			assert(s->sample_sequence == 9 && !fixture.pushed && c.pending_sample_valid);
			ssc_response(&c.client, &c.peer, &txn, &response);
			assert(s->sample_sequence == 10 && fixture.pushed == 1);
			assert(s->sample[0] == 10000000 && !s->sample[1] && !s->sample[2]);
			assert(!c.pending_sample_valid && !fixture.sent && !fixture.handles);
			checks++;
		}
	}
	printf("Actual STK3BCx ALS callbacks: %u small/large and packed/unpacked reports wait for ACK before scalar lux publication\n", checks);
}
