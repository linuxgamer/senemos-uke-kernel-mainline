// SPDX-License-Identifier: GPL-2.0-only
/* Synthetic public-shape fixtures; no device values or identifiers. */
static void rear_metadata_contract(void)
{
	static const char *names[] = { "sip1328 back ambient", "sip1328 back ambient-extra",
		"stk_stk3bcx", "synthetic-sensor" };
	struct uke_ssc_attributes a;
	unsigned int checks = 0;

	for (unsigned int sensor = 0; sensor < SSC_SENSOR_COUNT; sensor++) {
		for (unsigned int name = 0; name < sizeof(names) / sizeof(names[0]); name++) {
			for (unsigned int physical = 0; physical < 2; physical++) {
				bool expected = physical || (sensor == 4 && name == 0);
				bool usable;

				a = (struct uke_ssc_attributes){ .available = true,
					.physical = physical, .rate_count = 1, .rate = {0x40000000} };
				strcpy(a.name, names[name]);
				usable = ssc_attributes_usable(&ssc_descriptions[sensor], &a);
				assert(usable == expected);
				checks++;
			}
		}
	}
	for (unsigned int fault = 0; fault < 4; fault++) {
		a = (struct uke_ssc_attributes){ .available = fault != 0,
			.physical = false, .hlos_incompatible = fault == 1,
			.stream_type = fault == 2 ? 2 : 0,
			.rate_count = fault == 3 ? 0 : 1, .rate = {0x40000000} };
		strcpy(a.name, names[0]);
		assert(!ssc_attributes_usable(&ssc_descriptions[4], &a));
		checks++;
	}
	printf("Actual SIP1328 metadata: %u exact logical endpoint and retained physical/available/HLOS/stream/rate checks passed\n", checks);
}

static void rear_vectors(void)
{
	static const char *names[] = { "sip1328 back ambient", "sip1328 back ambient-extra",
		"stk_stk3bcx", "synthetic-als" };
	struct ssc_controller c;
	unsigned int checks = 0;

	for (unsigned int shape = 0; shape <= 17; shape++) {
		for (unsigned int packed = 0; packed < 2; packed++) {
			for (unsigned int name = 0; name < sizeof(names) / sizeof(names[0]); name++) {
				struct fixture_bytes b = als_payload(shape, packed, 3, -1, 0);
				struct uke_ssc_event e = { .message = 1025, .ticks = 200,
					.payload = {b.data, b.size} };
				s64 values[3] = {77, 88, 99};
				bool expected = shape == 2 || (shape == 6 && name == 0);

				setup(&c);
				strcpy(c.sensor[4].attributes.name, names[name]);
				assert((ssc_sample_values(&c.sensor[4], &e, values) == 0) == expected);
				if (expected)
					assert(values[0] == 10000000 && values[1] == 88 && values[2] == 99);
				checks++;
			}
		}
	}
	for (unsigned int packed = 0; packed < 2; packed++) {
		for (unsigned int channel = 0; channel < 6; channel++) {
			struct fixture_bytes b = als_payload(6, packed, 3, channel, 0x7fc00000);
			struct uke_ssc_event e = { .message = 1025, .ticks = 200,
				.payload = {b.data, b.size} };
			s64 values[3] = {};

			setup(&c);
			strcpy(c.sensor[4].attributes.name, names[0]);
			assert(ssc_sample_values(&c.sensor[4], &e, values) == -EBADMSG);
			checks++;
		}
		for (unsigned int fault = 0; fault < 3; fault++) {
			struct fixture_bytes b = als_payload(6, packed, fault == 0 ? 0 : 3,
				fault == 1 ? 0 : -1, 0xbf800000);
			struct uke_ssc_event e = { .message = fault == 2 ? 1024 : 1025,
				.ticks = 200, .payload = {b.data, b.size} };
			s64 values[3] = {};

			setup(&c);
			strcpy(c.sensor[4].attributes.name, names[0]);
			assert(ssc_sample_values(&c.sensor[4], &e, values) ==
			       (fault == 0 ? -EAGAIN : fault == 1 ? -ERANGE : -ENOMSG));
			checks++;
		}
	}
	printf("Actual SIP1328 vectors: %u exact2/6 shape, finite/status/scaling and foreign-name checks passed\n", checks);
}

static void rear_reports(void)
{
	unsigned int checks = 0;

	for (unsigned int id = SSC_QMI_REPORT_SMALL; id <= SSC_QMI_REPORT_LARGE; id++) {
		for (unsigned int packed = 0; packed < 2; packed++) {
			for (unsigned int shape = 2; shape <= 6; shape += 4) {
				for (unsigned int ack_first = 0; ack_first < 2; ack_first++) {
					struct ssc_controller c;
					struct fixture_bytes attrs = {}, b = als_payload(shape, packed, 3, -1, 0);
					static const u8 yes[] = {40, 1}, no[] = {40, 0};
					static const u8 onchange[] = {33, 1, 0, 0, 0, 0, 0, 0, 0};
					static const u8 rate[] = {29, 0, 0, 0, 0x40};
					struct ssc_qmi_response response = { .result_valid = 1,
						.client_valid = 1, .client = 0x123456789ULL };
					struct qmi_txn txn = { .id = 17 };
					struct ssc_sensor *s;

					setup(&c);
					c.client_known = true; c.client_id = response.client;
					fixture.early_report_id = id;
					s = &c.sensor[4]; s->declared = true; s->ready = false;
					string_attribute(&attrs, 0, "sip1328 back ambient");
					string_attribute(&attrs, 2, "ambient_light_back");
					string_attribute(&attrs, 5, "sns_ambient_light.proto");
					attribute(&attrs, 3, yes, sizeof(yes));
					attribute(&attrs, 21, no, sizeof(no));
					attribute(&attrs, 16, onchange, sizeof(onchange));
					attribute(&attrs, 6, rate, sizeof(rate));
					recovery_event(&c, s, 128, attrs.data, attrs.size);
					assert(s->ready && !s->error && !s->attributes.physical);
					s->registered = s->buffered = true; s->stream_active = false;
					c.pending = true; c.pending_id = txn.id;
					c.pending_sensor = s; c.pending_command = UKE_SSC_ON_CHANGE;
					if (ack_first) ssc_response(&c.client, &c.peer, &txn, &response);
					recovery_event(&c, s, 1025, b.data, b.size);
					if (!ack_first) {
						assert(s->sample_sequence == 9 && !fixture.pushed && c.pending_sample_valid);
						ssc_response(&c.client, &c.peer, &txn, &response);
					}
					assert(s->sample_sequence == 10 && fixture.pushed == 1);
					assert(s->sample[0] == 10000000 && !s->sample[1] && !s->sample[2]);
					assert(!fixture.sent && !fixture.handles && !c.pending_sample_valid);
					checks++;
				}
			}
		}
	}
	printf("Actual SIP1328 callbacks: %u virtual metadata, small/large, packed/unpacked,2/6 shape and ACK-order checks passed\n", checks);
}
