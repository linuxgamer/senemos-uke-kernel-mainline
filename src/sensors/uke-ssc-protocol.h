/* SPDX-License-Identifier: GPL-2.0-only OR MIT */
#ifndef UKE_SSC_PROTOCOL_H
#define UKE_SSC_PROTOCOL_H

#include <linux/types.h>

#define UKE_SSC_MESSAGE_MAX 16384
#define UKE_SSC_EVENTS_MAX 32
#define UKE_SSC_VALUES_MAX 16
#define UKE_SSC_SUIDS_MAX 32
#define UKE_SSC_REQUEST_MAX 256
#define UKE_SSC_RATES_MAX 32

struct uke_ssc_suid { u64 low, high; };
struct uke_ssc_view { const u8 *data; size_t size; };
struct uke_ssc_event {
	u32 message;
	u64 ticks;
	struct uke_ssc_view payload;
};
struct uke_ssc_events {
	unsigned int count;
	struct uke_ssc_event event[UKE_SSC_EVENTS_MAX];
};
struct uke_ssc_sample {
	unsigned int count, status;
	/* IEEE754 wire bits, never kernel floating-point values or inferred units. */
	u32 value[UKE_SSC_VALUES_MAX];
};
struct uke_ssc_suids {
	unsigned int count;
	struct uke_ssc_suid suid[UKE_SSC_SUIDS_MAX];
};

struct uke_ssc_attributes {
	char name[129], datatype[65];
	unsigned int stream_type, rate_count;
	u32 rate[UKE_SSC_RATES_MAX];
	bool available, physical, hlos_incompatible;
};

struct uke_ssc_proximity {
	bool near, has_adc;
	u32 adc;
	unsigned int status;
};

enum uke_ssc_command {
	UKE_SSC_LOOKUP,
	UKE_SSC_ATTRIBUTES,
	UKE_SSC_STREAM,
	UKE_SSC_ON_CHANGE,
	UKE_SSC_DISABLE,
};

/* No I/O. Output must be disjoint from the input. Views borrow the input,
 * which must stay immutable for their lifetime. Failure preserves the output.
 */
int uke_ssc_decode_events(struct uke_ssc_view wire, struct uke_ssc_suid expected,
			 struct uke_ssc_events *out);
int uke_ssc_decode_sample(struct uke_ssc_view wire, unsigned int dimensions,
			 struct uke_ssc_sample *out);
int uke_ssc_decode_suids(struct uke_ssc_view wire, const char *datatype,
			struct uke_ssc_suids *out);
int uke_ssc_decode_attributes(struct uke_ssc_view wire, const char *datatype,
			      const char *api, struct uke_ssc_attributes *out);
int uke_ssc_decode_proximity(struct uke_ssc_view wire, bool sar,
			     struct uke_ssc_proximity *out);
/* Encodes protobuf only; QMI framing and transaction/client ownership are separate. */
int uke_ssc_encode_request(enum uke_ssc_command command, struct uke_ssc_suid suid,
			   const char *datatype, u32 rate_bits,
			   u8 *out, size_t capacity, size_t *bytes);
/* Integer scaling, truncating toward zero. Does not assign physical units. */
int uke_ssc_fixed(u32 ieee754, u32 multiplier, s64 *out);

#endif
