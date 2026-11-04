// SPDX-License-Identifier: GPL-2.0-only
/* Uke firmware-owned SSC sensors. No AP bus probing or calibration writes.
 * QMI transaction dispatch follows Linux 7.3.1 qmi_interface.c:
 * Copyright (c) 2017, Linaro Ltd.
 */
#include <linux/completion.h>
#include <linux/device.h>
#include <linux/iio/buffer.h>
#include <linux/iio/iio.h>
#include <linux/iio/kfifo_buf.h>
#include <linux/jiffies.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/platform_device.h>
#include <linux/pm.h>
#include <linux/slab.h>
#include <linux/soc/qcom/qmi.h>
#include <linux/spinlock.h>
#include <linux/sysfs.h>
#include <linux/workqueue.h>
#include "uke-ssc-protocol.h"

#define SSC_SERVICE 400
#define SSC_TIMEOUT msecs_to_jiffies(5000)
#define SSC_QMI_REQUEST 0x20
#define SSC_QMI_REPORT_SMALL 0x21
#define SSC_QMI_REPORT_LARGE 0x22
#define SSC_REPORT_TYPE_LARGE 1
#define SSC_QMI_REPORT_MAX (UKE_SSC_MESSAGE_MAX + 16)
#define SSC_SENSOR_COUNT 8

enum ssc_kind { SSC_ACCEL, SSC_GYRO, SSC_MAG, SSC_LIGHT, SSC_PROXIMITY, SSC_SAR, SSC_TEMPERATURE };
struct ssc_description {
	const char *datatype, *api, *name;
	enum ssc_kind kind;
	enum iio_chan_type channel;
	unsigned int dimensions;
	u32 multiplier;
};
static const struct ssc_description ssc_descriptions[SSC_SENSOR_COUNT] = {
	{ "accel", "sns_accel.proto", "uke-ssc-accel", SSC_ACCEL, IIO_ACCEL, 3, 1000000 },
	{ "gyro", "sns_gyro.proto", "uke-ssc-gyro", SSC_GYRO, IIO_ANGL_VEL, 3, 1000000 },
	/* The sensor API uses microtesla; IIO's magnetic unit is gauss. */
	{ "mag", "sns_mag.proto", "uke-ssc-mag", SSC_MAG, IIO_MAGN, 3, 10000 },
	{ "ambient_light", "sns_ambient_light.proto", "uke-ssc-front-light", SSC_LIGHT, IIO_LIGHT, 2, 1000000 },
	{ "ambient_light_back", "sns_ambient_light.proto", "uke-ssc-rear-light", SSC_LIGHT, IIO_LIGHT, 2, 1000000 },
	{ "proximity", "sns_proximity.proto", "uke-ssc-proximity", SSC_PROXIMITY, IIO_PROXIMITY, 1, 1 },
	{ "sar", "sns_sar.proto", "uke-ssc-sar", SSC_SAR, IIO_PROXIMITY, 1, 1 },
	/* The physical sensor API uses Celsius; IIO temperature uses millicelsius. */
	{ "sensor_temperature", "sns_sensor_temperature.proto", "uke-ssc-sensor-temperature", SSC_TEMPERATURE, IIO_TEMP, 1, 1000 },
};

struct ssc_controller;
struct ssc_sensor {
	struct ssc_controller *controller;
	const struct ssc_description *description;
	struct iio_dev *iio;
	struct iio_chan_spec channel[4];
	struct uke_ssc_suid suid;
	struct uke_ssc_attributes attributes;
	struct completion metadata_done, sample_done;
	u64 revision, sample_sequence, ticks;
	s64 sample[3];
	u32 rate;
	int error;
	bool declared, have_suid, ready, registered, need_metadata, need_apply;
	bool buffered, stream_active, need_stop, buffer_fault;
};

struct ssc_endpoint {
	struct list_head list;
	struct sockaddr_qrtr address;
};

enum ssc_failure_stage {
	SSC_FAILURE_NONE, SSC_FAILURE_CLIENT, SSC_FAILURE_LOOKUP,
	SSC_FAILURE_ATTRIBUTES, SSC_FAILURE_REGISTRATION,
};

struct ssc_observation {
	unsigned int services, lookup_fault, suspended, connected;
	unsigned int declared, discovered, ready, registered;
	int last_error;
	enum ssc_failure_stage last_stage;
};

struct ssc_controller {
	struct device *dev;
	struct qmi_handle lookup, client;
	struct workqueue_struct *workqueue;
	struct work_struct reconcile;
	/* All blocking requests and client release are serialized here. */
	struct mutex control;
	/* Callbacks never acquire control; invalidate before draining workers. */
	spinlock_t state;
	struct list_head endpoints;
	struct sockaddr_qrtr peer;
	struct ssc_sensor sensor[SSC_SENSOR_COUNT];
	unsigned int endpoint_count;
	u64 generation, client_generation;
	u64 client_id;
	u16 pending_id;
	enum uke_ssc_command pending_command;
	struct ssc_sensor *pending_sensor;
	bool removed, paused, client_open, client_known, pending, lookup_fault;
	/* Last discovery failure in this namespace generation; no payload data. */
	int last_discovery_error;
	enum ssc_failure_stage last_discovery_stage;
};

struct ssc_qmi_request {
	u32 length;
	u8 payload[UKE_SSC_REQUEST_MAX];
	u8 report_type_valid, report_type;
};
struct ssc_qmi_response {
	u8 result_valid;
	struct qmi_response_type_v01 result;
	u8 client_valid;
	u64 client;
	u8 error_valid;
	u32 error;
};
struct ssc_qmi_report {
	u8 client_valid;
	u64 client;
	u8 payload_valid;
	/* QMI_DATA_LEN uses u32 in memory even with a two-byte wire count. */
	u32 length;
	u8 payload[UKE_SSC_MESSAGE_MAX];
};

#define SSC_ELEM(t, n, s, a, tlv, structure, member) \
	{ .data_type = t, .elem_len = n, .elem_size = s, .array_type = a, \
	  .tlv_type = tlv, .offset = offsetof(structure, member) }
static const struct qmi_elem_info ssc_request_ei[] = {
	SSC_ELEM(QMI_DATA_LEN, 1, 2, NO_ARRAY, 1, struct ssc_qmi_request, length),
	SSC_ELEM(QMI_UNSIGNED_1_BYTE, UKE_SSC_REQUEST_MAX, 1, VAR_LEN_ARRAY, 1, struct ssc_qmi_request, payload),
	SSC_ELEM(QMI_OPT_FLAG, 1, 1, NO_ARRAY, 0x10, struct ssc_qmi_request, report_type_valid),
	SSC_ELEM(QMI_UNSIGNED_1_BYTE, 1, 1, NO_ARRAY, 0x10, struct ssc_qmi_request, report_type),
	{ .data_type = QMI_EOTI },
};
static const struct qmi_elem_info ssc_response_ei[] = {
	SSC_ELEM(QMI_OPT_FLAG, 1, 1, NO_ARRAY, 2, struct ssc_qmi_response, result_valid),
	{ .data_type = QMI_STRUCT, .elem_len = 1,
	  .elem_size = sizeof(struct qmi_response_type_v01), .array_type = NO_ARRAY,
	  .tlv_type = 2, .offset = offsetof(struct ssc_qmi_response, result),
	  .ei_array = qmi_response_type_v01_ei },
	SSC_ELEM(QMI_OPT_FLAG, 1, 1, NO_ARRAY, 0x10, struct ssc_qmi_response, client_valid),
	SSC_ELEM(QMI_UNSIGNED_8_BYTE, 1, 8, NO_ARRAY, 0x10, struct ssc_qmi_response, client),
	SSC_ELEM(QMI_OPT_FLAG, 1, 1, NO_ARRAY, 0x11, struct ssc_qmi_response, error_valid),
	SSC_ELEM(QMI_UNSIGNED_4_BYTE, 1, 4, NO_ARRAY, 0x11, struct ssc_qmi_response, error),
	{ .data_type = QMI_EOTI },
};
static const struct qmi_elem_info ssc_report_ei[] = {
	SSC_ELEM(QMI_OPT_FLAG, 1, 1, NO_ARRAY, 1, struct ssc_qmi_report, client_valid),
	SSC_ELEM(QMI_UNSIGNED_8_BYTE, 1, 8, NO_ARRAY, 1, struct ssc_qmi_report, client),
	SSC_ELEM(QMI_OPT_FLAG, 1, 1, NO_ARRAY, 2, struct ssc_qmi_report, payload_valid),
	SSC_ELEM(QMI_DATA_LEN, 1, 2, NO_ARRAY, 2, struct ssc_qmi_report, length),
	SSC_ELEM(QMI_UNSIGNED_1_BYTE, UKE_SSC_MESSAGE_MAX, 1, VAR_LEN_ARRAY, 2, struct ssc_qmi_report, payload),
	{ .data_type = QMI_EOTI },
};

static bool ssc_uid_equal(struct uke_ssc_suid a, struct uke_ssc_suid b)
{
	return a.low == b.low && a.high == b.high;
}

static bool ssc_current(struct ssc_controller *c)
{
	return !c->removed && !c->paused && !c->lookup_fault && c->client_open &&
	       c->endpoint_count == 1 && c->client_generation == c->generation;
}

static void ssc_observe(struct ssc_controller *c, struct ssc_observation *out)
{
	unsigned long flags;
	unsigned int i;

	*out = (struct ssc_observation){};
	spin_lock_irqsave(&c->state, flags);
	out->services = c->endpoint_count;
	out->lookup_fault = c->lookup_fault;
	out->suspended = c->paused;
	out->connected = ssc_current(c);
	out->last_error = c->last_discovery_error;
	out->last_stage = c->last_discovery_stage;
	for (i = 0; i < SSC_SENSOR_COUNT; i++) {
		const struct ssc_sensor *s = &c->sensor[i];

		if (!s->declared)
			continue;
		out->declared++;
		out->registered += s->registered;
		if (out->connected) {
			out->discovered += s->have_suid;
			out->ready += s->ready;
		}
	}
	spin_unlock_irqrestore(&c->state, flags);
}

static void ssc_record_failure(struct ssc_controller *c, u64 generation,
			       enum ssc_failure_stage stage, int error)
{
	unsigned long flags;

	if (error >= 0)
		return;
	spin_lock_irqsave(&c->state, flags);
	if (!c->removed && c->generation == generation) {
		c->last_discovery_error = error;
		c->last_discovery_stage = stage;
	}
	spin_unlock_irqrestore(&c->state, flags);
}

static const char *ssc_failure_name(enum ssc_failure_stage stage)
{
	switch (stage) {
	case SSC_FAILURE_NONE: return "none";
	case SSC_FAILURE_CLIENT: return "client";
	case SSC_FAILURE_LOOKUP: return "lookup";
	case SSC_FAILURE_ATTRIBUTES: return "attributes";
	case SSC_FAILURE_REGISTRATION: return "registration";
	default: return "unknown";
	}
}

#define SSC_OBSERVATION_ATTRIBUTE(name, member, format) \
static ssize_t name##_show(struct device *dev, struct device_attribute *attr, char *buf) \
{ \
	struct ssc_observation snapshot; \
	ssc_observe(dev_get_drvdata(dev), &snapshot); \
	return sysfs_emit(buf, format "\n", snapshot.member); \
} \
static DEVICE_ATTR_RO(name)

SSC_OBSERVATION_ATTRIBUTE(ssc_service_count, services, "%u");
SSC_OBSERVATION_ATTRIBUTE(ssc_lookup_fault, lookup_fault, "%u");
SSC_OBSERVATION_ATTRIBUTE(ssc_suspended, suspended, "%u");
SSC_OBSERVATION_ATTRIBUTE(ssc_client_connected, connected, "%u");
SSC_OBSERVATION_ATTRIBUTE(ssc_declared_sensors, declared, "%u");
SSC_OBSERVATION_ATTRIBUTE(ssc_discovered_sensors, discovered, "%u");
SSC_OBSERVATION_ATTRIBUTE(ssc_ready_sensors, ready, "%u");
SSC_OBSERVATION_ATTRIBUTE(ssc_registered_sensors, registered, "%u");
SSC_OBSERVATION_ATTRIBUTE(ssc_last_error, last_error, "%d");

static ssize_t ssc_last_error_stage_show(struct device *dev,
				       struct device_attribute *attr, char *buf)
{
	struct ssc_observation snapshot;

	ssc_observe(dev_get_drvdata(dev), &snapshot);
	return sysfs_emit(buf, "%s\n", ssc_failure_name(snapshot.last_stage));
}
static DEVICE_ATTR_RO(ssc_last_error_stage);

static struct attribute *ssc_observation_attrs[] = {
	&dev_attr_ssc_service_count.attr,
	&dev_attr_ssc_lookup_fault.attr,
	&dev_attr_ssc_suspended.attr,
	&dev_attr_ssc_client_connected.attr,
	&dev_attr_ssc_declared_sensors.attr,
	&dev_attr_ssc_discovered_sensors.attr,
	&dev_attr_ssc_ready_sensors.attr,
	&dev_attr_ssc_registered_sensors.attr,
	&dev_attr_ssc_last_error.attr,
	&dev_attr_ssc_last_error_stage.attr,
	NULL,
};
ATTRIBUTE_GROUPS(ssc_observation);
#undef SSC_OBSERVATION_ATTRIBUTE

static void ssc_schedule_locked(struct ssc_controller *c)
{
	if (!c->removed && !c->paused)
		queue_work(c->workqueue, &c->reconcile);
}

static void ssc_invalidate_locked(struct ssc_controller *c)
{
	unsigned int i;

	c->generation++;
	c->last_discovery_error = 0;
	c->last_discovery_stage = SSC_FAILURE_NONE;
	for (i = 0; i < SSC_SENSOR_COUNT; i++) {
		struct ssc_sensor *s = &c->sensor[i];

		s->ready = false;
		s->stream_active = false;
		s->error = -ENOTCONN;
		s->ticks = 0;
		memset(s->sample, 0, sizeof(s->sample));
		complete_all(&s->metadata_done);
		complete_all(&s->sample_done);
	}
}

static int ssc_new_server(struct qmi_handle *qmi, struct qmi_service *service)
{
	struct ssc_controller *c = container_of(qmi, struct ssc_controller, lookup);
	struct ssc_endpoint *endpoint;
	unsigned long flags;

	if (service->service != SSC_SERVICE || service->version != 1 || service->instance != 0 ||
	    !service->node || !service->port || service->port == QRTR_PORT_CTRL)
		return -ENODEV;
	endpoint = kzalloc(sizeof(*endpoint), GFP_KERNEL);
	if (!endpoint) {
		spin_lock_irqsave(&c->state, flags);
		/* An untracked endpoint cannot be treated as proof of uniqueness. */
		c->lookup_fault = true;
		ssc_invalidate_locked(c);
		ssc_schedule_locked(c);
		spin_unlock_irqrestore(&c->state, flags);
		return -ENOMEM;
	}
	endpoint->address = (struct sockaddr_qrtr){ AF_QIPCRTR, service->node, service->port };
	service->priv = endpoint;
	spin_lock_irqsave(&c->state, flags);
	list_add_tail(&endpoint->list, &c->endpoints);
	c->endpoint_count++;
	ssc_invalidate_locked(c);
	ssc_schedule_locked(c);
	spin_unlock_irqrestore(&c->state, flags);
	return 0;
}

static void ssc_del_server(struct qmi_handle *qmi, struct qmi_service *service)
{
	struct ssc_controller *c = container_of(qmi, struct ssc_controller, lookup);
	struct ssc_endpoint *endpoint = service->priv;
	unsigned long flags;

	if (!endpoint)
		return;
	spin_lock_irqsave(&c->state, flags);
	list_del(&endpoint->list);
	c->endpoint_count--;
	ssc_invalidate_locked(c);
	ssc_schedule_locked(c);
	spin_unlock_irqrestore(&c->state, flags);
	service->priv = NULL;
	kfree(endpoint);
}

static void ssc_client_reset(struct qmi_handle *qmi)
{
	struct ssc_controller *c = container_of(qmi, struct ssc_controller, client);
	unsigned long flags;

	spin_lock_irqsave(&c->state, flags);
	ssc_invalidate_locked(c);
	ssc_schedule_locked(c);
	spin_unlock_irqrestore(&c->state, flags);
}

static void ssc_response(struct qmi_handle *qmi, struct sockaddr_qrtr *peer,
			 struct qmi_txn *txn, const void *decoded)
{
	struct ssc_controller *c = container_of(qmi, struct ssc_controller, client);
	const struct ssc_qmi_response *response = decoded;
	unsigned long flags;
	int ret = 0;

	spin_lock_irqsave(&c->state, flags);
	if (peer->sq_node != c->peer.sq_node || peer->sq_port != c->peer.sq_port ||
	    !c->pending || txn->id != c->pending_id) {
		spin_unlock_irqrestore(&c->state, flags);
		return;
	}
	if (!ssc_current(c))
		ret = -ENOTCONN;
	else if (!response->result_valid || response->result.result || response->result.error ||
		 !response->client_valid || (response->error_valid && response->error) ||
		 (c->client_known && response->client != c->client_id))
		ret = -EREMOTEIO;
	else {
		c->client_id = response->client;
		c->client_known = true;
		if (c->pending_sensor && (c->pending_command == UKE_SSC_STREAM ||
					 c->pending_command == UKE_SSC_ON_CHANGE))
			c->pending_sensor->stream_active = true;
	}
	spin_unlock_irqrestore(&c->state, flags);
	/* The QMI helper owns txn->lock while invoking this response handler. */
	txn->result = ret;
	complete(&txn->completion);
}

static int ssc_request(struct ssc_controller *c, struct ssc_sensor *sensor,
			 enum uke_ssc_command command, struct uke_ssc_suid uid,
			 const char *datatype, u32 rate)
{
	/* Match the documented QMI Control selector used by the working SSC route. */
	struct ssc_qmi_request request = {
		.report_type_valid = 1, .report_type = SSC_REPORT_TYPE_LARGE,
	};
	struct qmi_txn txn;
	size_t bytes;
	unsigned long flags;
	int ret;

	lockdep_assert_held(&c->control);
	spin_lock_irqsave(&c->state, flags);
	ret = ssc_current(c) ? 0 : -ENOTCONN;
	spin_unlock_irqrestore(&c->state, flags);
	if (ret)
		return ret;
	ret = uke_ssc_encode_request(command, uid, datatype, rate,
				    request.payload, sizeof(request.payload), &bytes);
	if (ret)
		return ret;
	request.length = bytes;
	ret = qmi_txn_init(&c->client, &txn, NULL, NULL);
	if (ret)
		return ret;
	spin_lock_irqsave(&c->state, flags);
	if (!ssc_current(c)) {
		spin_unlock_irqrestore(&c->state, flags);
		qmi_txn_cancel(&txn);
		return -ENOTCONN;
	}
	c->pending = true;
	c->pending_id = txn.id;
	c->pending_command = command;
	c->pending_sensor = sensor;
	spin_unlock_irqrestore(&c->state, flags);
	ret = qmi_send_request(&c->client, &c->peer, &txn, SSC_QMI_REQUEST,
			       UKE_SSC_REQUEST_MAX + 9, ssc_request_ei, &request);
	if (ret)
		qmi_txn_cancel(&txn);
	else
		ret = qmi_txn_wait(&txn, SSC_TIMEOUT);
	spin_lock_irqsave(&c->state, flags);
	c->pending = false;
	c->pending_sensor = NULL;
	if (!ssc_current(c))
		ret = -ENOTCONN;
	spin_unlock_irqrestore(&c->state, flags);
	return ret;
}

static u32 ssc_rate(const struct uke_ssc_attributes *attributes)
{
	u32 rate = 0;
	unsigned int i;

	/* Prefer an advertised rate of at least 10 Hz; retain slower-only devices. */
	for (i = 0; i < attributes->rate_count; i++)
		if (!rate || (rate < 0x41200000U && attributes->rate[i] > rate) ||
		    (rate >= 0x41200000U && attributes->rate[i] >= 0x41200000U && attributes->rate[i] < rate))
			rate = attributes->rate[i];
	return rate;
}

static int ssc_sample_values(struct ssc_sensor *s, const struct uke_ssc_event *event,
			     s64 value[3])
{
	const struct ssc_description *d = s->description;
	struct uke_ssc_sample sample;
	struct uke_ssc_proximity proximity;
	unsigned int i;
	int ret;

	if (d->kind == SSC_PROXIMITY || d->kind == SSC_SAR) {
		if (event->message != (s->attributes.stream_type ? 769 : 1031))
			return -ENOMSG;
		ret = uke_ssc_decode_proximity(event->payload, d->kind == SSC_SAR, &proximity);
		if (ret || !proximity.status)
			return ret ? ret : -EAGAIN;
		value[0] = proximity.near;
		return 0;
	}
	if (event->message != 1025)
		return -ENOMSG;
	ret = uke_ssc_decode_sample(event->payload, d->dimensions, &sample);
	if (ret || !sample.status)
		return ret ? ret : -EAGAIN;
	/* This API specifies HIGH for valid data and UNRELIABLE while stabilizing. */
	if (d->kind == SSC_TEMPERATURE && sample.status != 3)
		return -EAGAIN;
	for (i = 0; i < (d->dimensions == 3 ? 3 : 1); i++) {
		ret = uke_ssc_fixed(sample.value[i], d->multiplier, &value[i]);
		if (ret || (d->kind == SSC_LIGHT && value[i] < 0))
			return ret ? ret : -ERANGE;
	}
	return 0;
}

static bool ssc_attributes_usable(const struct ssc_description *description,
				 const struct uke_ssc_attributes *attributes)
{
	bool streaming = description->dimensions == 3 || description->kind == SSC_TEMPERATURE;

	return attributes->available && attributes->physical && !attributes->hlos_incompatible &&
	       attributes->stream_type <= 1 && (attributes->stream_type || ssc_rate(attributes)) &&
	       (!streaming || !attributes->stream_type);
}

static int ssc_read_scale(const struct ssc_description *description, int *val, int *val2)
{
	if (description->multiplier == 1)
		return -EINVAL;
	if (description->kind == SSC_TEMPERATURE) {
		*val = 1; *val2 = 0;
		return IIO_VAL_INT;
	}
	*val = 0; *val2 = 1;
	return IIO_VAL_INT_PLUS_MICRO;
}

static void ssc_report(struct qmi_handle *qmi, struct sockaddr_qrtr *peer,
		       struct qmi_txn *txn, const void *decoded)
{
	struct ssc_controller *c = container_of(qmi, struct ssc_controller, client);
	const struct ssc_qmi_report *report = decoded;
	struct uke_ssc_view wire = { report->payload, report->length };
	const struct uke_ssc_suid lookup = { 0xababababababababULL, 0xababababababababULL };
	struct uke_ssc_events *events;
	struct uke_ssc_suids suids;
	struct uke_ssc_attributes attributes;
	unsigned long flags;
	unsigned int i, j;
	bool is_lookup;
	int ret;

	if (!report->client_valid || !report->payload_valid || !report->length ||
	    report->length > UKE_SSC_MESSAGE_MAX)
		return;
	events = kmalloc(sizeof(*events), GFP_KERNEL);
	if (!events)
		return;
	spin_lock_irqsave(&c->state, flags);
	if (!ssc_current(c) || !c->client_known || report->client != c->client_id ||
	    peer->sq_node != c->peer.sq_node || peer->sq_port != c->peer.sq_port)
		goto out;
	is_lookup = !uke_ssc_decode_events(wire, lookup, events);
	for (i = 0; i < SSC_SENSOR_COUNT; i++) {
		struct ssc_sensor *s = &c->sensor[i];

		if (!s->declared)
			continue;
		if (!is_lookup && (!s->have_suid || uke_ssc_decode_events(wire, s->suid, events)))
			continue;
		for (j = 0; j < events->count; j++) {
			const struct uke_ssc_event *event = &events->event[j];
			s64 scan[4] = {};

			if (is_lookup) {
				if (event->message != 768)
					continue;
				ret = uke_ssc_decode_suids(event->payload, s->description->datatype, &suids);
				if (ret)
					continue;
				if (s->have_suid && (suids.count != 1 || !ssc_uid_equal(s->suid, suids.suid[0]))) {
					/* Closing the socket also releases requests to the old SUID. */
					ssc_invalidate_locked(c);
					ssc_schedule_locked(c);
					goto out;
				}
				if (suids.count != 1) {
					s->have_suid = s->ready = s->stream_active = false;
					s->revision++;
					s->error = -ENODEV;
					complete_all(&s->sample_done);
				} else if (!s->have_suid || !ssc_uid_equal(s->suid, suids.suid[0])) {
					s->suid = suids.suid[0];
					s->have_suid = s->need_metadata = true;
					s->ready = s->stream_active = false;
					s->revision++;
					s->error = -EAGAIN;
					complete_all(&s->sample_done);
					ssc_schedule_locked(c);
				}
				continue;
			}
			if (event->message == 128) {
				ret = uke_ssc_decode_attributes(event->payload, s->description->datatype,
							 s->description->api, &attributes);
				s->ready = false;
				s->error = ret ? ret : -ENODEV;
				if (!ret) {
					s->attributes = attributes;
					s->rate = ssc_rate(&attributes);
					s->ready = ssc_attributes_usable(s->description, &attributes);
					if (s->ready)
						s->error = 0;
				}
				if (!s->ready) {
					s->need_stop |= s->stream_active;
					complete_all(&s->sample_done);
				}
				s->need_apply = true;
				complete_all(&s->metadata_done);
				ssc_schedule_locked(c);
				continue;
			}
			if (event->message == 130) {
				s->ready = false;
				s->buffer_fault |= s->buffered && s->stream_active;
				s->need_stop |= s->stream_active;
				s->error = -EREMOTEIO;
				complete_all(&s->metadata_done);
				complete_all(&s->sample_done);
				ssc_schedule_locked(c);
				continue;
			}
			if (!s->ready || !s->stream_active || !event->ticks ||
			    (s->ticks && event->ticks <= s->ticks) || ssc_sample_values(s, event, scan))
				continue;
			s->ticks = event->ticks;
			memcpy(s->sample, scan, sizeof(s->sample));
			s->sample_sequence++;
			s->error = 0;
			if (s->buffered && s->registered)
				iio_push_to_buffers_with_ts(s->iio, scan, sizeof(scan), iio_get_time_ns(s->iio));
			complete(&s->sample_done);
		}
	}
out:
	spin_unlock_irqrestore(&c->state, flags);
	kfree(events);
}

static void ssc_message(struct qmi_handle *qmi, struct sockaddr_qrtr *peer,
			const void *data, size_t count)
{
	struct uke_ssc_view wire = { data, count };
	struct ssc_qmi_response response = {};
	struct ssc_qmi_report *report;
	struct qmi_txn *txn;
	u16 transaction;
	bool is_response;
	int ret;

	if (count < 7)
		return;
	is_response = wire.data[0] == QMI_RESPONSE;
	if (uke_ssc_qmi_validate(wire, is_response, &transaction))
		return;
	if (is_response) {
		/* Same lifetime/lock order as qmi_handle_message; never retain txn. */
		mutex_lock(&qmi->txn_lock);
		txn = idr_find(&qmi->txns, transaction);
		if (!txn) {
			mutex_unlock(&qmi->txn_lock);
			return;
		}
		mutex_lock(&txn->lock);
		mutex_unlock(&qmi->txn_lock);
		ret = qmi_decode_message(data, count, ssc_response_ei, &response);
		if (ret >= 0 && (size_t)ret == count - 7)
			ssc_response(qmi, peer, txn, &response);
		mutex_unlock(&txn->lock);
	} else {
		report = kzalloc(sizeof(*report), GFP_KERNEL);
		if (!report)
			return;
		ret = qmi_decode_message(data, count, ssc_report_ei, report);
		if (ret >= 0 && (size_t)ret == count - 7)
			ssc_report(qmi, peer, NULL, report);
		kfree(report);
	}
}

static const struct qmi_ops ssc_client_ops = {
	.net_reset = ssc_client_reset, .msg_handler = ssc_message,
};
static const struct qmi_ops ssc_lookup_ops = { .new_server = ssc_new_server, .del_server = ssc_del_server };

static void ssc_close_client(struct ssc_controller *c);

static int ssc_start(struct ssc_sensor *s)
{
	struct ssc_controller *c = s->controller;
	struct uke_ssc_suid uid;
	u32 rate;
	unsigned long flags;
	bool on_change;
	int ret;

	spin_lock_irqsave(&c->state, flags);
	if (!ssc_current(c) || !s->ready) {
		spin_unlock_irqrestore(&c->state, flags);
		return -ENODEV;
	}
	uid = s->suid;
	on_change = s->attributes.stream_type == 1;
	rate = on_change ? 0 : s->rate;
	s->ticks = 0;
	s->stream_active = false;
	s->error = 0;
	reinit_completion(&s->sample_done);
	spin_unlock_irqrestore(&c->state, flags);
	ret = ssc_request(c, s, on_change ? UKE_SSC_ON_CHANGE : UKE_SSC_STREAM, uid, NULL, rate);
	if (ret) {
		/* A lost acknowledgement leaves stream ownership uncertain. */
		spin_lock_irqsave(&c->state, flags);
		s->buffer_fault |= s->buffered;
		ssc_invalidate_locked(c);
		ssc_schedule_locked(c);
		spin_unlock_irqrestore(&c->state, flags);
		ssc_close_client(c);
	}
	return ret;
}

static int ssc_stop(struct ssc_sensor *s)
{
	struct ssc_controller *c = s->controller;
	struct uke_ssc_suid uid;
	unsigned long flags;
	bool active;
	int ret = 0;

	spin_lock_irqsave(&c->state, flags);
	active = ssc_current(c) && s->have_suid && s->stream_active;
	uid = s->suid;
	s->stream_active = false;
	s->need_stop = false;
	s->ticks = 0;
	spin_unlock_irqrestore(&c->state, flags);
	if (active)
		ret = ssc_request(c, s, UKE_SSC_DISABLE, uid, NULL, 0);
	if (ret) {
		/* A refused stop closes the socket rather than retaining an unknown request. */
		spin_lock_irqsave(&c->state, flags);
		ssc_invalidate_locked(c);
		ssc_schedule_locked(c);
		spin_unlock_irqrestore(&c->state, flags);
		ssc_close_client(c);
	}
	return ret;
}

static int ssc_read_raw(struct iio_dev *iio, const struct iio_chan_spec *channel,
			int *val, int *val2, long mask)
{
	struct ssc_sensor *s = *(struct ssc_sensor **)iio_priv(iio);
	struct ssc_controller *c = s->controller;
	unsigned long flags;
	u64 sequence;
	s64 value = 0;
	int ret, stop_ret;

	if (mask == IIO_CHAN_INFO_SCALE)
		return ssc_read_scale(s->description, val, val2);
	if (mask != IIO_CHAN_INFO_RAW)
		return -EINVAL;
	if (!iio_device_claim_direct(iio))
		return -EBUSY;
	mutex_lock(&c->control);
	spin_lock_irqsave(&c->state, flags);
	sequence = s->sample_sequence;
	spin_unlock_irqrestore(&c->state, flags);
	ret = ssc_start(s);
	if (!ret) {
		if (!wait_for_completion_timeout(&s->sample_done, SSC_TIMEOUT))
			ret = -ETIMEDOUT;
		spin_lock_irqsave(&c->state, flags);
		if (!ret) {
			if (!ssc_current(c) || !s->ready || s->error || s->sample_sequence == sequence)
				ret = s->error ? s->error : -ENODATA;
			else
				value = s->sample[channel->address];
		}
		spin_unlock_irqrestore(&c->state, flags);
	}
	stop_ret = ssc_stop(s);
	if (!ret)
		ret = stop_ret;
	spin_lock_irqsave(&c->state, flags);
	if (!ret && (!ssc_current(c) || !s->ready))
		ret = -ENOTCONN;
	spin_unlock_irqrestore(&c->state, flags);
	mutex_unlock(&c->control);
	iio_device_release_direct(iio);
	if (ret)
		return ret;
	iio_val_s64_decompose(value, val, val2);
	return IIO_VAL_INT_64;
}

static int ssc_buffer_enable(struct iio_dev *iio)
{
	struct ssc_sensor *s = *(struct ssc_sensor **)iio_priv(iio);
	struct ssc_controller *c = s->controller;
	unsigned long flags;
	int ret;

	mutex_lock(&c->control);
	spin_lock_irqsave(&c->state, flags);
	s->buffered = true;
	s->buffer_fault = false;
	spin_unlock_irqrestore(&c->state, flags);
	ret = ssc_start(s);
	if (ret) {
		spin_lock_irqsave(&c->state, flags);
		s->buffered = false;
		spin_unlock_irqrestore(&c->state, flags);
		ssc_stop(s);
	}
	mutex_unlock(&c->control);
	return ret;
}

static int ssc_buffer_disable(struct iio_dev *iio)
{
	struct ssc_sensor *s = *(struct ssc_sensor **)iio_priv(iio);
	struct ssc_controller *c = s->controller;
	unsigned long flags;

	mutex_lock(&c->control);
	spin_lock_irqsave(&c->state, flags);
	s->buffered = false;
	spin_unlock_irqrestore(&c->state, flags);
	ssc_stop(s);
	mutex_unlock(&c->control);
	return 0;
}

static const struct iio_info ssc_iio_info = { .read_raw = ssc_read_raw };
static const struct iio_buffer_setup_ops ssc_buffer_ops = {
	.postenable = ssc_buffer_enable, .predisable = ssc_buffer_disable,
};
static const unsigned long ssc_xyz_masks[] = { 7, 0 };
static const unsigned long ssc_scalar_masks[] = { 1, 0 };

static void ssc_close_client(struct ssc_controller *c)
{
	unsigned long flags;
	bool open;
	unsigned int i;

	lockdep_assert_held(&c->control);
	spin_lock_irqsave(&c->state, flags);
	open = c->client_open;
	c->client_open = c->client_known = false;
	c->pending = false;
	for (i = 0; i < SSC_SENSOR_COUNT; i++) {
		struct ssc_sensor *s = &c->sensor[i];

		s->ready = s->stream_active = false;
		s->error = -ENOTCONN;
		s->ticks = 0;
		memset(s->sample, 0, sizeof(s->sample));
		complete_all(&s->metadata_done);
		complete_all(&s->sample_done);
	}
	spin_unlock_irqrestore(&c->state, flags);
	if (open)
		qmi_handle_release(&c->client);
}

static void ssc_reconcile(struct work_struct *work)
{
	struct ssc_controller *c = container_of(work, struct ssc_controller, reconcile);
	const struct uke_ssc_suid lookup = { 0xababababababababULL, 0xababababababababULL };
	struct sockaddr_qrtr peer;
	unsigned long flags;
	unsigned int i;
	bool recreate, allowed;
	u64 generation;
	int ret;

	mutex_lock(&c->control);
	spin_lock_irqsave(&c->state, flags);
	allowed = !c->removed && !c->paused && !c->lookup_fault && c->endpoint_count == 1;
	recreate = !ssc_current(c);
	generation = c->generation;
	if (allowed)
		peer = list_first_entry(&c->endpoints, struct ssc_endpoint, list)->address;
	spin_unlock_irqrestore(&c->state, flags);
	if (recreate)
		ssc_close_client(c);
	if (!allowed)
		goto out;
	if (recreate) {
		ret = qmi_handle_init(&c->client, SSC_QMI_REPORT_MAX, &ssc_client_ops, NULL);
		if (ret) {
			ssc_record_failure(c, generation, SSC_FAILURE_CLIENT, ret);
			goto out;
		}
		spin_lock_irqsave(&c->state, flags);
		c->client_open = true;
		c->client_generation = generation;
		c->peer = peer;
		for (i = 0; i < SSC_SENSOR_COUNT; i++) {
			c->sensor[i].have_suid = false;
			c->sensor[i].need_metadata = c->sensor[i].need_apply = false;
			c->sensor[i].need_stop = false;
		}
		spin_unlock_irqrestore(&c->state, flags);
		for (i = 0; i < SSC_SENSOR_COUNT; i++) {
			if (!c->sensor[i].declared)
				continue;
			ret = ssc_request(c, NULL, UKE_SSC_LOOKUP, lookup, c->sensor[i].description->datatype, 0);
			if (ret) {
				ssc_record_failure(c, generation, SSC_FAILURE_LOOKUP, ret);
				ssc_close_client(c);
				goto out;
			}
		}
	}
	for (i = 0; i < SSC_SENSOR_COUNT; i++) {
		struct ssc_sensor *s = &c->sensor[i];
		struct uke_ssc_suid uid;
		bool metadata, apply, ready, buffered, stop;
		u64 revision;

		spin_lock_irqsave(&c->state, flags);
		metadata = ssc_current(c) && s->have_suid && s->need_metadata;
		stop = s->need_stop;
		uid = s->suid;
		revision = s->revision;
		s->need_metadata = false;
		if (metadata)
			reinit_completion(&s->metadata_done);
		spin_unlock_irqrestore(&c->state, flags);
		if (stop)
			ssc_stop(s);
		if (metadata) {
			ret = ssc_request(c, s, UKE_SSC_ATTRIBUTES, uid, NULL, 0);
			if (!ret && !wait_for_completion_timeout(&s->metadata_done, SSC_TIMEOUT))
				ret = -ETIMEDOUT;
			if (!ret) {
				spin_lock_irqsave(&c->state, flags);
				ret = s->ready ? 0 : s->error;
				spin_unlock_irqrestore(&c->state, flags);
			}
			ssc_record_failure(c, generation, SSC_FAILURE_ATTRIBUTES, ret);
		}
		spin_lock_irqsave(&c->state, flags);
		ready = ssc_current(c) && s->ready && s->revision == revision;
		apply = s->need_apply;
		s->need_apply = false;
		buffered = s->buffered && !s->buffer_fault;
		spin_unlock_irqrestore(&c->state, flags);
		if (ready && !s->registered) {
			ret = iio_device_register(s->iio);
			if (ret) {
				ssc_record_failure(c, generation, SSC_FAILURE_REGISTRATION, ret);
				continue;
			}
			spin_lock_irqsave(&c->state, flags);
			s->registered = true;
			spin_unlock_irqrestore(&c->state, flags);
		}
		if (ready && apply && buffered)
			ssc_start(s);
	}
out:
	mutex_unlock(&c->control);
}

static int ssc_allocate_iio(struct ssc_controller *c, struct ssc_sensor *s)
{
	struct iio_dev *iio;
	unsigned int count = s->description->dimensions == 3 ? 3 : 1, i;
	const enum iio_modifier axis[] = { IIO_MOD_X, IIO_MOD_Y, IIO_MOD_Z };

	iio = devm_iio_device_alloc(c->dev, sizeof(struct ssc_sensor *));
	if (!iio)
		return -ENOMEM;
	*(struct ssc_sensor **)iio_priv(iio) = s;
	s->iio = iio;
	for (i = 0; i < count; i++) {
		s->channel[i] = (struct iio_chan_spec){
			.type = s->description->channel, .address = i, .scan_index = i,
			.info_mask_separate = BIT(IIO_CHAN_INFO_RAW),
			.scan_type = { .sign = 's', .realbits = 64, .storagebits = 64, .endianness = IIO_CPU },
		};
		if (count == 3) {
			s->channel[i].modified = 1;
			s->channel[i].channel2 = axis[i];
		}
		if (s->description->multiplier != 1)
			s->channel[i].info_mask_shared_by_type = BIT(IIO_CHAN_INFO_SCALE);
	}
	s->channel[count] = IIO_CHAN_SOFT_TIMESTAMP(count);
	iio->name = s->description->name;
	iio->info = &ssc_iio_info;
	iio->modes = INDIO_DIRECT_MODE;
	iio->channels = s->channel;
	iio->num_channels = count + 1;
	iio->available_scan_masks = count == 3 ? ssc_xyz_masks : ssc_scalar_masks;
	return devm_iio_kfifo_buffer_setup(c->dev, iio, &ssc_buffer_ops);
}

static int ssc_suspend(struct device *dev)
{
	struct ssc_controller *c = dev_get_drvdata(dev);
	unsigned long flags;

	spin_lock_irqsave(&c->state, flags);
	c->paused = true;
	ssc_invalidate_locked(c);
	spin_unlock_irqrestore(&c->state, flags);
	cancel_work_sync(&c->reconcile);
	mutex_lock(&c->control);
	ssc_close_client(c);
	mutex_unlock(&c->control);
	return 0;
}

static int ssc_resume(struct device *dev)
{
	struct ssc_controller *c = dev_get_drvdata(dev);
	unsigned long flags;

	spin_lock_irqsave(&c->state, flags);
	c->paused = false;
	ssc_schedule_locked(c);
	spin_unlock_irqrestore(&c->state, flags);
	return 0;
}

static int ssc_link_adsp(struct device *consumer, struct device *supplier)
{
	int ret;

	/* Serialize the bound check and link creation against supplier unbind. */
	device_lock(supplier);
	if (!device_is_bound(supplier))
		ret = -EPROBE_DEFER;
	else if (!device_link_add(consumer, supplier, DL_FLAG_AUTOREMOVE_CONSUMER))
		ret = -ENOMEM;
	else
		ret = 0;
	device_unlock(supplier);
	return ret;
}

static int ssc_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct ssc_controller *c;
	struct device_node *adsp, *child;
	struct platform_device *supplier;
	unsigned int i;
	int ret;

	if (!of_machine_is_compatible("xiaomi,uke") || !of_machine_is_compatible("qcom,sm7675"))
		return -ENODEV;
	if (of_property_count_u32_elems(dev->of_node, "remoteproc") != 1)
		return -EINVAL;
	adsp = of_parse_phandle(dev->of_node, "remoteproc", 0);
	if (!adsp || !of_device_is_available(adsp)) {
		of_node_put(adsp);
		return -EINVAL;
	}
	supplier = of_find_device_by_node(adsp);
	of_node_put(adsp);
	if (!supplier)
		return -EPROBE_DEFER;
	ret = ssc_link_adsp(dev, &supplier->dev);
	put_device(&supplier->dev);
	if (ret)
		return ret;
	c = devm_kzalloc(dev, sizeof(*c), GFP_KERNEL);
	if (!c)
		return -ENOMEM;
	c->dev = dev;
	mutex_init(&c->control);
	spin_lock_init(&c->state);
	INIT_LIST_HEAD(&c->endpoints);
	INIT_WORK(&c->reconcile, ssc_reconcile);
	for (i = 0; i < SSC_SENSOR_COUNT; i++) {
		c->sensor[i].controller = c;
		c->sensor[i].description = &ssc_descriptions[i];
		init_completion(&c->sensor[i].metadata_done);
		init_completion(&c->sensor[i].sample_done);
	}
	for_each_available_child_of_node(dev->of_node, child) {
		const char *datatype;

		if (of_property_read_string(child, "qcom,ssc-datatype", &datatype)) {
			of_node_put(child);
			return -EINVAL;
		}
		for (i = 0; i < SSC_SENSOR_COUNT; i++) {
			if (strcmp(datatype, ssc_descriptions[i].datatype))
				continue;
			if (c->sensor[i].declared) {
				of_node_put(child);
				return -EINVAL;
			}
			c->sensor[i].declared = true;
		}
	}
	for (i = 0; i < SSC_SENSOR_COUNT; i++) {
		if (!c->sensor[i].declared)
			continue;
		ret = ssc_allocate_iio(c, &c->sensor[i]);
		if (ret)
			return ret;
	}
	c->workqueue = alloc_ordered_workqueue("uke-ssc", WQ_FREEZABLE | WQ_MEM_RECLAIM);
	if (!c->workqueue)
		return -ENOMEM;
	ret = qmi_handle_init(&c->lookup, 0, &ssc_lookup_ops, NULL);
	if (ret)
		goto destroy_workqueue;
	platform_set_drvdata(pdev, c);
	ret = qmi_add_lookup(&c->lookup, SSC_SERVICE, 1, 0);
	if (ret)
		goto release_lookup;
	return 0;
release_lookup:
	spin_lock_irq(&c->state);
	c->removed = true;
	ssc_invalidate_locked(c);
	spin_unlock_irq(&c->state);
	qmi_handle_release(&c->lookup);
	cancel_work_sync(&c->reconcile);
	mutex_lock(&c->control);
	ssc_close_client(c);
	mutex_unlock(&c->control);
	for (i = 0; i < SSC_SENSOR_COUNT; i++)
		if (c->sensor[i].registered)
			iio_device_unregister(c->sensor[i].iio);
destroy_workqueue:
	destroy_workqueue(c->workqueue);
	return ret;
}

static void ssc_remove(struct platform_device *pdev)
{
	struct ssc_controller *c = platform_get_drvdata(pdev);
	unsigned long flags;
	unsigned int i;

	spin_lock_irqsave(&c->state, flags);
	c->removed = true;
	ssc_invalidate_locked(c);
	spin_unlock_irqrestore(&c->state, flags);
	qmi_handle_release(&c->lookup);
	cancel_work_sync(&c->reconcile);
	mutex_lock(&c->control);
	ssc_close_client(c);
	mutex_unlock(&c->control);
	/* Never unregister while holding control: a sysfs reader may be waiting for it. */
	for (i = 0; i < SSC_SENSOR_COUNT; i++)
		if (c->sensor[i].registered)
			iio_device_unregister(c->sensor[i].iio);
	destroy_workqueue(c->workqueue);
}

static DEFINE_SIMPLE_DEV_PM_OPS(ssc_pm_ops, ssc_suspend, ssc_resume);
static const struct of_device_id ssc_match[] = {
	{ .compatible = "xiaomi,uke-ssc-iio" }, {},
};
MODULE_DEVICE_TABLE(of, ssc_match);
static struct platform_driver ssc_driver = {
	.probe = ssc_probe, .remove = ssc_remove,
	.driver = {
		.name = "uke-ssc-iio", .of_match_table = ssc_match,
		.pm = pm_sleep_ptr(&ssc_pm_ops), .dev_groups = ssc_observation_groups,
	},
};
module_platform_driver(ssc_driver);
MODULE_DESCRIPTION("Xiaomi Uke firmware-owned SSC IIO transport");
MODULE_LICENSE("GPL");
