// SPDX-License-Identifier: GPL-2.0-only
/* Included after the actual production definitions/callbacks. No real providers. */
static struct {
	int init_error,send_error,protobuf_error;
	int handle_error,register_error;
	unsigned int live,cancelled,released,sent,pushed,decoded;
	unsigned int handles,registrations;
	bool no_ack,foreign,changed_client,stale_on_wait;
	bool metadata_timeout,metadata_invalid,stale_registration;
	unsigned int last_command;
	struct ssc_controller *controller;
	s64 pushed_value[3];
} fixture;

static int qmi_handle_init(struct qmi_handle *qmi, size_t maximum,
			   const void *ops, const void *handlers)
{
	assert(qmi == &fixture.controller->client && !qmi->live);
	assert(maximum == SSC_QMI_REPORT_MAX && ops == &ssc_client_ops && !handlers);
	fixture.handles++;
	if (fixture.handle_error)
		return fixture.handle_error;
	qmi->live = true;
	return 0;
}

static unsigned long wait_for_completion_timeout(struct completion *done, unsigned long timeout)
{
	struct ssc_controller *c = fixture.controller;
	unsigned int i;

	assert(c->control.locked && !c->state && timeout == SSC_TIMEOUT);
	for (i = 0; i < SSC_SENSOR_COUNT; i++) {
		struct ssc_sensor *s = &c->sensor[i];

		if (&s->metadata_done != done)
			continue;
		if (fixture.metadata_timeout)
			return 0;
		s->ready = !fixture.metadata_invalid;
		s->error = fixture.metadata_invalid ? -ENODEV : 0;
		done->done++;
		return 1;
	}
	assert(!"unexpected completion");
	return 0;
}

static int iio_device_register(struct iio_dev *iio)
{
	struct ssc_controller *c = fixture.controller;

	assert(c->control.locked && !c->state && iio == c->sensor[0].iio);
	fixture.registrations++;
	if (fixture.stale_registration)
		ssc_invalidate_locked(c);
	return fixture.register_error;
}

int upstream_qmi_decode_message(const void *,size_t,const struct qmi_elem_info *,void *);
int qmi_decode_message(const void *data,size_t size,const struct qmi_elem_info *ei,void *out)
{ fixture.decoded++;return upstream_qmi_decode_message(data,size,ei,out); }

static int qmi_txn_init(struct qmi_handle *qmi, struct qmi_txn *txn, const void *ei, void *dest)
{
	(void)ei; (void)dest;
	assert(qmi->live);
	if (fixture.init_error) return fixture.init_error;
	*txn = (struct qmi_txn){ .qmi=qmi,.id=17 };
	qmi->txns.txn=txn;
	fixture.live++;
	return 0;
}
static int qmi_send_request(struct qmi_handle *qmi, struct sockaddr_qrtr *peer,
	struct qmi_txn *txn, int message, size_t maxlen, const void *ei, const void *body)
{
	const struct ssc_qmi_request *request = body;
	struct ssc_qmi_response response = { .result_valid=1,.client_valid=1,.client=0x123456789ULL };
	struct sockaddr_qrtr sender = *peer;
	size_t size = maxlen;
	u8 *wire = qmi_encode_message(QMI_REQUEST,message,&size,txn->id,ei,body);
	assert(!IS_ERR(wire) && message == SSC_QMI_REQUEST && size == request->length + 16);
	assert(maxlen == UKE_SSC_REQUEST_MAX + 9 && request->report_type_valid && request->report_type == 1);
	assert(wire[0] == QMI_REQUEST && wire[3] == 0x20 && wire[7] == 1);
	assert((wire[10] | (unsigned int)wire[11] << 8) == request->length);
	assert(!memcmp(wire+12,request->payload,request->length));
	assert(wire[size-4]==0x10 && wire[size-3]==1 && !wire[size-2] && wire[size-1]==1);
	free(wire);
	fixture.last_command = request->payload[21] | (unsigned int)request->payload[22] << 8;
	fixture.sent++;
	if (fixture.send_error) return fixture.send_error;
	if (!fixture.no_ack) {
		if (fixture.foreign) sender.sq_node++;
		if (fixture.changed_client) response.client++;
		if (fixture.protobuf_error) { response.error_valid=1;response.error=fixture.protobuf_error; }
		size=64;wire=qmi_encode_message(QMI_RESPONSE,0x20,&size,txn->id,ssc_response_ei,&response);
		assert(!IS_ERR(wire));ssc_message(qmi,&sender,wire,size);free(wire);
	}
	return 0;
}
static int qmi_txn_wait(struct qmi_txn *txn, unsigned long timeout)
{
	assert(timeout == SSC_TIMEOUT && fixture.live);
	fixture.live--;
	assert(!txn->lock.locked && !txn->qmi->txn_lock.locked);
	txn->qmi->txns.txn=NULL;
	if (fixture.stale_on_wait) ssc_invalidate_locked(fixture.controller);
	return txn->completion.done ? txn->result : -ETIMEDOUT;
}
static void qmi_txn_cancel(struct qmi_txn *txn)
{
	assert(fixture.live);fixture.live--;fixture.cancelled++;txn->qmi->txns.txn=NULL;
}
static void qmi_handle_release(struct qmi_handle *qmi)
{
	assert(!fixture.live && !fixture.controller->client_open && !ssc_current(fixture.controller));
	assert(qmi->live);qmi->live=false;fixture.released++;
}
static int iio_push_to_buffers_with_ts(struct iio_dev *iio, void *data,size_t size,s64 timestamp)
{
	(void)iio;assert(size >= 32 && timestamp == 1000000);
	memcpy(fixture.pushed_value,data,sizeof(fixture.pushed_value));fixture.pushed++;return 0;
}
static s64 iio_get_time_ns(struct iio_dev *iio) { (void)iio;return 1000000; }

static void setup(struct ssc_controller *c)
{
	static struct workqueue_struct queue;
	unsigned int i;
	memset(c,0,sizeof(*c));memset(&fixture,0,sizeof(fixture));memset(&queue,0,sizeof(queue));
	fixture.controller=c;c->workqueue=&queue;c->control.locked=true;
	c->client_open=true;c->client.live=true;c->endpoint_count=1;
	c->generation=c->client_generation=1;
	c->peer=(struct sockaddr_qrtr){AF_QIPCRTR,3,4};
	for(i=0;i<SSC_SENSOR_COUNT;i++) {
		struct ssc_sensor *s=&c->sensor[i];
		s->controller=c;s->description=&ssc_descriptions[i];
		s->ready=true;s->have_suid=true;s->suid=(struct uke_ssc_suid){0x123,0x456};
		s->rate=0x41200000;s->sample_sequence=9;s->sample[0]=777;s->ticks=123;
	}
}

static unsigned int popcount8(unsigned int value)
{
	unsigned int n = 0;
	for (unsigned int bit = 1; bit < 256; bit <<= 1)
		n += !!(value & bit);
	return n;
}

static void observation_contract(void)
{
	struct ssc_controller c, before;
	struct ssc_observation view;
	unsigned int checks = 0;
	const char *names[] = {
		"ssc_service_count", "ssc_lookup_fault", "ssc_suspended", "ssc_client_connected",
		"ssc_declared_sensors", "ssc_discovered_sensors", "ssc_ready_sensors",
		"ssc_registered_sensors", "ssc_last_error", "ssc_last_error_stage",
	};

	assert(ssc_observation_groups[0]->attrs == ssc_observation_attrs);
	assert(!ssc_observation_groups[1]);
	for (unsigned int mask = 0; mask < 256; mask++) {
		unsigned int discovered = ((mask << 3) | (mask >> 5)) & 255;
		unsigned int ready = (mask ^ 0x93) & 255, registered = (mask ^ 0x69) & 255;

		for (unsigned int state = 0; state < 8; state++) {
			setup(&c);
			for (unsigned int i = 0; i < SSC_SENSOR_COUNT; i++) {
				c.sensor[i].declared = !!(mask & (1u << i));
				c.sensor[i].have_suid = !!(discovered & (1u << i));
				c.sensor[i].ready = !!(ready & (1u << i));
				c.sensor[i].registered = !!(registered & (1u << i));
			}
			if (state == 1) c.paused = true;
			if (state == 2) c.removed = true;
			if (state == 3) c.lookup_fault = true;
			if (state == 4) c.endpoint_count = 0;
			if (state == 5) c.endpoint_count = 2;
			if (state == 6) c.client_open = false;
			if (state == 7) c.client_generation--;
			c.last_discovery_error = -ETIMEDOUT;
			c.last_discovery_stage = SSC_FAILURE_LOOKUP;
			before = c;
			ssc_observe(&c, &view);
			assert(!memcmp(&before, &c, sizeof(c)));
			assert(view.services == c.endpoint_count && view.lookup_fault == (state == 3));
			assert(view.suspended == (state == 1) && view.connected == (state == 0));
			assert(view.declared == popcount8(mask));
			assert(view.discovered == (state ? 0 : popcount8(mask & discovered)));
			assert(view.ready == (state ? 0 : popcount8(mask & ready)));
			assert(view.registered == popcount8(mask & registered));
			assert(view.last_error == -ETIMEDOUT && view.last_stage == SSC_FAILURE_LOOKUP);
			struct device dev = { .driver_data = &c };
			const int expected[] = { (int)c.endpoint_count, state == 3, state == 1, !state,
				(int)popcount8(mask), state ? 0 : (int)popcount8(mask & discovered),
				state ? 0 : (int)popcount8(mask & ready), (int)popcount8(mask & registered),
				-ETIMEDOUT };
			for (unsigned int i = 0; i < 10; i++) {
				char buffer[4096], wanted[64];
				struct attribute *a = ssc_observation_attrs[i];
				struct device_attribute *attr = container_of(a, struct device_attribute, attr);
				assert(!strcmp(a->name, names[i]) && a->mode == 0444 && !attr->store);
				if (i == 9) snprintf(wanted, sizeof(wanted), "lookup\n");
				else snprintf(wanted, sizeof(wanted), "%d\n", expected[i]);
				ssize_t n = attr->show(&dev, attr, buffer);
				assert(n == (ssize_t)strlen(wanted) && !strcmp(buffer, wanted));
				assert(!memcmp(&before, &c, sizeof(c)));
				checks++;
			}
			assert(!ssc_observation_attrs[10] && !fixture.sent && !fixture.handles && !fixture.registrations);
		}
	}
	setup(&c);
	ssc_record_failure(&c, c.generation, SSC_FAILURE_CLIENT, -ENOMEM);
	assert(c.last_discovery_error == -ENOMEM && c.last_discovery_stage == SSC_FAILURE_CLIENT);
	ssc_record_failure(&c, c.generation - 1, SSC_FAILURE_LOOKUP, -EIO);
	assert(c.last_discovery_error == -ENOMEM && c.last_discovery_stage == SSC_FAILURE_CLIENT);
	ssc_record_failure(&c, c.generation, SSC_FAILURE_LOOKUP, 0);
	ssc_record_failure(&c, c.generation, SSC_FAILURE_LOOKUP, 7);
	assert(c.last_discovery_error == -ENOMEM);
	c.removed = true;
	ssc_record_failure(&c, c.generation, SSC_FAILURE_ATTRIBUTES, -EINVAL);
	assert(c.last_discovery_error == -ENOMEM);
	c.removed = false;
	ssc_invalidate_locked(&c);
	assert(!c.last_discovery_error && c.last_discovery_stage == SSC_FAILURE_NONE);
	assert(!strcmp(ssc_failure_name(SSC_FAILURE_NONE), "none"));
	assert(!strcmp(ssc_failure_name(SSC_FAILURE_CLIENT), "client"));
	assert(!strcmp(ssc_failure_name(SSC_FAILURE_LOOKUP), "lookup"));
	assert(!strcmp(ssc_failure_name(SSC_FAILURE_ATTRIBUTES), "attributes"));
	assert(!strcmp(ssc_failure_name(SSC_FAILURE_REGISTRATION), "registration"));
	assert(!strcmp(ssc_failure_name((enum ssc_failure_stage)999), "unknown"));
	printf("Actual SSC observation: %u read-only callback checks, generation/refusal, current-state gating and no transport or private data passed\n", checks);
}

static void discovery_failure_contract(void)
{
	struct ssc_controller c;
	struct ssc_endpoint endpoint = { .address = { AF_QIPCRTR, 3, 4 } };
	struct iio_dev iio;

	for (unsigned int fault = 0; fault < 9; fault++) {
		setup(&c);
		c.control.locked = false;
		c.sensor[0].declared = true;
		c.sensor[0].iio = &iio;
		c.sensor[0].ready = false;
		c.sensor[0].error = -EAGAIN;
		c.sensor[0].need_metadata = true;
		for (unsigned int i = 1; i < SSC_SENSOR_COUNT; i++) {
			c.sensor[i].ready = false;
			c.sensor[i].have_suid = false;
		}
		c.endpoints.next = &endpoint.list;
		c.endpoints.prev = &endpoint.list;
		if (fault < 3) {
			c.client_open = false;
			c.client.live = false;
		}
		if (fault == 0) fixture.handle_error = -ENOMEM;
		if (fault == 1) fixture.send_error = -EPIPE;
		if (fault == 2) fixture.stale_on_wait = true;
		if (fault == 3) fixture.send_error = -EPIPE;
		if (fault == 4) fixture.metadata_timeout = true;
		if (fault == 5) fixture.metadata_invalid = true;
		if (fault == 6) fixture.register_error = -ENOMEM;
		if (fault == 8) { fixture.register_error = -EIO; fixture.stale_registration = true; }
		ssc_reconcile(&c.reconcile);
		assert(!c.control.locked && !c.state && !fixture.live);
		const int errors[] = { -ENOMEM, -EPIPE, 0, -EPIPE, -ETIMEDOUT, -ENODEV, -ENOMEM, 0, 0 };
		const enum ssc_failure_stage stages[] = { SSC_FAILURE_CLIENT, SSC_FAILURE_LOOKUP,
			SSC_FAILURE_NONE, SSC_FAILURE_ATTRIBUTES, SSC_FAILURE_ATTRIBUTES,
			SSC_FAILURE_ATTRIBUTES, SSC_FAILURE_REGISTRATION, SSC_FAILURE_NONE, SSC_FAILURE_NONE };
		assert(c.last_discovery_error == errors[fault] && c.last_discovery_stage == stages[fault]);
		assert(c.sensor[0].registered == (fault == 7));
		if (fault == 0) assert(fixture.handles == 1 && !fixture.sent);
		if (fault == 1 || fault == 2) assert(fixture.released == 1 && !c.client_open);
		if (fault >= 6) assert(fixture.registrations == 1);
	}
	puts("Actual SSC reconcile: client, lookup, attributes, registration and stale-generation failures retain the correct stage; valid metadata still registers IIO");
}
static void ownership(void)
{
	struct ssc_controller c;
	struct ssc_sensor *s;
	unsigned int fault,i;
	setup(&c);s=&c.sensor[0];
	assert(!ssc_start(s) && s->stream_active && c.client_known && c.client_id==0x123456789ULL);
	assert(fixture.last_command==513 && !fixture.live && !c.pending);
	assert(!ssc_stop(s) && !s->stream_active && fixture.last_command==10 && fixture.sent==2);
	ssc_close_client(&c);assert(fixture.released==1 && !c.client_open);
	for(i=0;i<SSC_SENSOR_COUNT;i++)assert(!c.sensor[i].ready && !c.sensor[i].ticks && !c.sensor[i].sample[0]);
	for(fault=0;fault<6;fault++) {
		setup(&c);s=&c.sensor[0];s->buffered=true;
		if(fault==0)fixture.init_error=-ENOMEM;
		if(fault==1)fixture.send_error=-EIO;
		if(fault==2)fixture.no_ack=true;
		if(fault==3)fixture.foreign=true;
		if(fault==4)fixture.protobuf_error=6;
		if(fault==5)fixture.stale_on_wait=true;
		assert(ssc_start(s)<0 && s->buffer_fault && !c.client_open && !fixture.live);
		assert(fixture.released==1 && !s->stream_active && !s->ready && !c.pending);
	}
	setup(&c);s=&c.sensor[0];
	assert(!ssc_start(s));fixture.changed_client=true;
	assert(ssc_stop(s)==-EREMOTEIO && fixture.released==1 && !fixture.live);
	setup(&c);s=&c.sensor[0];assert(!ssc_start(s));fixture.no_ack=true;
	assert(ssc_stop(s)==-ETIMEDOUT && fixture.released==1);
	setup(&c);c.client_open=false;c.client.live=false;
	assert(ssc_request(&c,NULL,UKE_SSC_ATTRIBUTES,(struct uke_ssc_suid){1,2},NULL,0)==-ENOTCONN);
	assert(!fixture.sent && !fixture.live);
	setup(&c);c.sensor[0].buffered=true;
	ssc_invalidate_locked(&c);
	for(i=0;i<SSC_SENSOR_COUNT;i++)assert(!c.sensor[i].ready && !c.sensor[i].ticks &&
		!c.sensor[i].sample[0] && c.sensor[i].error==-ENOTCONN && c.sensor[i].sample_done.done);
	assert(c.sensor[0].buffered && !ssc_current(&c));
	setup(&c);c.endpoint_count=2;assert(!ssc_current(&c));
	c.endpoint_count=1;c.lookup_fault=true;assert(!ssc_current(&c));
}
static void qmi_wire(void)
{
	struct ssc_qmi_response source={.result_valid=1,.client_valid=1,.client=0x123456789ULL,.error_valid=1},decoded={};
	struct ssc_qmi_report *in=calloc(1,sizeof(*in)),*out=calloc(1,sizeof(*out));
	size_t size=64;
	u16 transaction;
	size_t cut;
	u8 *wire=qmi_encode_message(QMI_RESPONSE,0x20,&size,17,ssc_response_ei,&source);
	assert(!IS_ERR(wire) && !uke_ssc_qmi_validate((struct uke_ssc_view){wire,size},true,&transaction));
	assert(transaction==17 && qmi_decode_message(wire,size,ssc_response_ei,&decoded)>=0);
	assert(decoded.result_valid && decoded.client_valid && decoded.client==source.client && decoded.error_valid);
	free(wire);
	assert(in && out);in->client_valid=in->payload_valid=1;in->client=source.client;
	in->length=3;memcpy(in->payload,"abc",3);size=SSC_QMI_REPORT_MAX;
	wire=qmi_encode_message(QMI_INDICATION,0x21,&size,0,ssc_report_ei,in);
	assert(!IS_ERR(wire) && size==26 && !uke_ssc_qmi_validate((struct uke_ssc_view){wire,size},false,&transaction));
	assert(qmi_decode_message(wire,size,ssc_report_ei,out)>=0);
	assert(out->client_valid && out->payload_valid && out->length==3 && !memcmp(out->payload,"abc",3));
	/* The documented large ID has identical length/TLV admission. */
	wire[3]=SSC_QMI_REPORT_LARGE;
	assert(!uke_ssc_qmi_validate((struct uke_ssc_view){wire,size},false,&transaction));
	for(unsigned int id=0x20;id<=0x24;id++) {
		wire[3]=id;transaction=0xbeef;
		if(id==SSC_QMI_REPORT_SMALL || id==SSC_QMI_REPORT_LARGE)
			assert(!uke_ssc_qmi_validate((struct uke_ssc_view){wire,size},false,&transaction));
		else
			assert(uke_ssc_qmi_validate((struct uke_ssc_view){wire,size},false,&transaction)<0 && transaction==0xbeef);
	}
	wire[3]=SSC_QMI_REPORT_LARGE;
	for(cut=0;cut<size;cut++) {
		transaction=0xbeef;
		assert(uke_ssc_qmi_validate((struct uke_ssc_view){wire,cut},false,&transaction)<0 && transaction==0xbeef);
	}
	{
		u8 *duplicate=malloc(size+11);
		assert(duplicate);memcpy(duplicate,wire,size);memcpy(duplicate+size,wire+7,11);
		duplicate[5]=size+11-7;duplicate[6]=0;
		assert(uke_ssc_qmi_validate((struct uke_ssc_view){duplicate,size+11},false,&transaction)<0);
		free(duplicate);
	}
	assert(uke_ssc_qmi_validate((struct uke_ssc_view){wire,size-1},false,&transaction)<0);
	/* Body: client TLV11 bytes, payload TLV header3 bytes, little-endian length. */
	wire[21]=0xff;wire[22]=0xff;
	assert(uke_ssc_qmi_validate((struct uke_ssc_view){wire,size},false,&transaction)<0);
	{
		struct ssc_controller c;
		unsigned int decoded_count;
		setup(&c);decoded_count=fixture.decoded;
		ssc_message(&c.client,&c.peer,wire,size);
		assert(fixture.decoded==decoded_count && !fixture.pushed);
	}
	free(wire);
	for(unsigned int id=SSC_QMI_REPORT_SMALL;id<=SSC_QMI_REPORT_LARGE;id++) {
		in->length=UKE_SSC_MESSAGE_MAX;memset(in->payload,0x55,in->length);size=SSC_QMI_REPORT_MAX;
		wire=qmi_encode_message(QMI_INDICATION,id,&size,0,ssc_report_ei,in);
		assert(!IS_ERR(wire) && size==UKE_SSC_MESSAGE_MAX+23);
		assert(!uke_ssc_qmi_validate((struct uke_ssc_view){wire,size},false,&transaction));
		assert(qmi_decode_message(wire,size,ssc_report_ei,out)>=0 && out->length==UKE_SSC_MESSAGE_MAX);
		free(wire);
	}
	free(in);free(out);
}
struct fixture_bytes { u8 data[512];size_t size; };
static void put_le(struct fixture_bytes *b,u64 value,unsigned int size)
{ while(size--){assert(b->size<sizeof(b->data));b->data[b->size++]=value;value>>=8;} }
static void put_field(struct fixture_bytes *b,unsigned int field,const void *data,size_t size)
{
	size_t remaining=size;
	assert(b->size+size+4<=sizeof(b->data));put_le(b,(field<<3)|2,1);
	do {
		u8 byte=remaining&127;remaining>>=7;
		put_le(b,byte|(remaining?128:0),1);
	} while(remaining);
	if(size)
		memcpy(b->data+b->size,data,size);
	b->size+=size;
}
static struct fixture_bytes event_uid(struct uke_ssc_suid suid,unsigned int message,u64 ticks,const void *payload,size_t size)
{
	struct fixture_bytes b={},uid={},e={};
	put_le(&uid,9,1);put_le(&uid,suid.low,8);put_le(&uid,17,1);put_le(&uid,suid.high,8);
	put_field(&b,1,uid.data,uid.size);
	put_le(&e,13,1);put_le(&e,message,4);put_le(&e,17,1);put_le(&e,ticks,8);
	put_field(&e,3,payload,size);put_field(&b,2,e.data,e.size);return b;
}
static struct fixture_bytes event(unsigned int message,u64 ticks,const void *payload,size_t size)
{ return event_uid((struct uke_ssc_suid){0x123,0x456},message,ticks,payload,size); }
static void attribute(struct fixture_bytes *b,unsigned int id,const void *data,size_t size)
{
	struct fixture_bytes values={},entry={};
	put_field(&values,1,data,size);put_le(&entry,8,1);put_le(&entry,id,1);
	put_field(&entry,2,values.data,values.size);put_field(b,1,entry.data,entry.size);
}
static void string_attribute(struct fixture_bytes *b,unsigned int id,const char *text)
{
	struct fixture_bytes primitive={};
	put_field(&primitive,2,text,strlen(text)+1);attribute(b,id,primitive.data,primitive.size);
}
static void dispatch_large(struct ssc_controller *c,struct fixture_bytes *b,bool reject_unknown)
{
	struct ssc_qmi_report *r=calloc(1,sizeof(*r));
	size_t size=SSC_QMI_REPORT_MAX;
	u8 *wire;
	assert(r);r->client_valid=r->payload_valid=1;r->client=c->client_id;
	r->length=b->size;memcpy(r->payload,b->data,b->size);
	wire=qmi_encode_message(QMI_INDICATION,SSC_QMI_REPORT_LARGE,&size,0,ssc_report_ei,r);
	assert(!IS_ERR(wire));
	if(reject_unknown) {
		unsigned int decoded=fixture.decoded;
		wire[3]=0x23;ssc_message(&c->client,&c->peer,wire,size);
		assert(fixture.decoded==decoded && !c->sensor[0].ready);
		wire[3]=SSC_QMI_REPORT_LARGE;
	}
	ssc_message(&c->client,&c->peer,wire,size);
	free(wire);free(r);
}
static void large_discovery_metadata(void)
{
	struct ssc_controller c;
	struct fixture_bytes discovery={},uid={},attrs={},b;
	static const u8 yes[]={40,1};
	static const u8 continuous[]={33,0,0,0,0,0,0,0,0};
	static const u8 rate[]={29,0,0,0xd0,0x41}; /* 26 Hz */
	setup(&c);c.client_known=true;c.client_id=0x123456789ULL;
	c.sensor[0].declared=true;c.sensor[0].have_suid=c.sensor[0].ready=false;
	put_field(&discovery,1,"accel",5);
	put_le(&uid,9,1);put_le(&uid,0x123,8);put_le(&uid,17,1);put_le(&uid,0x456,8);
	put_field(&discovery,2,uid.data,uid.size);
	b=event_uid((struct uke_ssc_suid){0xababababababababULL,0xababababababababULL},
		768,200,discovery.data,discovery.size);
	dispatch_large(&c,&b,true);
	assert(c.sensor[0].have_suid && c.sensor[0].need_metadata && !c.sensor[0].ready);
	assert(c.sensor[0].suid.low==0x123 && c.sensor[0].suid.high==0x456);
	string_attribute(&attrs,0,"synthetic-accel");string_attribute(&attrs,2,"accel");
	string_attribute(&attrs,5,"sns_accel.proto");attribute(&attrs,3,yes,sizeof(yes));
	attribute(&attrs,21,yes,sizeof(yes));attribute(&attrs,16,continuous,sizeof(continuous));
	attribute(&attrs,6,rate,sizeof(rate));
	b=event(128,201,attrs.data,attrs.size);
	dispatch_large(&c,&b,true);
	assert(c.sensor[0].ready && !c.sensor[0].error && c.sensor[0].need_apply);
	assert(c.sensor[0].metadata_done.done && c.sensor[0].attributes.physical);
	assert(c.sensor[0].rate==0x41d00000);
}
static void reports(void)
{
	static const u8 xyz[]={13,0,0,0x80,0x3f,13,0,0,0x20,0xc0,13,0,0,0,0xbf,16,3};
	struct ssc_controller c;
	struct ssc_qmi_report *r=calloc(1,sizeof(*r));
	struct qmi_txn txn={};
	struct fixture_bytes b=event(1025,200,xyz,sizeof(xyz));
	assert(r);
	for(unsigned int id=SSC_QMI_REPORT_SMALL;id<=SSC_QMI_REPORT_LARGE;id++) {
		size_t size=SSC_QMI_REPORT_MAX;
		u8 *wire;
		setup(&c);c.client_known=true;c.client_id=0x123456789ULL;
		c.sensor[0].declared=c.sensor[0].registered=c.sensor[0].buffered=c.sensor[0].stream_active=true;
		r->client_valid=r->payload_valid=1;r->client=c.client_id;r->length=b.size;memcpy(r->payload,b.data,b.size);
		wire=qmi_encode_message(QMI_INDICATION,id,&size,0,ssc_report_ei,r);
		assert(!IS_ERR(wire));
		ssc_message(&c.client,&c.peer,wire,size);
		assert(fixture.pushed==1 && c.sensor[0].sample_sequence==10 && fixture.pushed_value[0]==1000000 && fixture.pushed_value[1]==-2500000);
		free(wire);
	}
	ssc_report(&c.client,&c.peer,&txn,r);assert(fixture.pushed==1);
	r->client++;ssc_report(&c.client,&c.peer,&txn,r);assert(fixture.pushed==1);r->client--;
	b=event(130,201,NULL,0);r->length=b.size;memcpy(r->payload,b.data,b.size);
	ssc_report(&c.client,&c.peer,&txn,r);
	assert(!c.sensor[0].ready && c.sensor[0].need_stop && c.sensor[0].buffer_fault && c.sensor[0].error==-EREMOTEIO);
	assert(fixture.pushed==1 && c.workqueue->queued);
	free(r);
}
static void units_and_rates(void)
{
	struct uke_ssc_attributes a={.rate_count=3,.rate={0x3f800000,0x40a00000,0x3dcccccd}};
	struct ssc_controller c;
	s64 values[3]={};
	static const u8 xyz[]={13,0,0,0x80,0x3f,13,0,0,0x20,0xc0,13,0,0,0,0xbf,16,3};
	struct uke_ssc_event e={.message=1025,.ticks=1,.payload={xyz,sizeof(xyz)}};
	assert(ssc_rate(&a)==0x40a00000);
	a=(struct uke_ssc_attributes){.rate_count=3,.rate={0x42c80000,0x41480000,0x41c80000}};
	assert(ssc_rate(&a)==0x41480000);
	setup(&c);assert(!ssc_sample_values(&c.sensor[2],&e,values));
	assert(values[0]==10000 && values[1]==-25000 && values[2]==-5000);
	e.message=768;assert(ssc_sample_values(&c.sensor[2],&e,values)==-ENOMSG);
}
static void temperature(void)
{
	struct ssc_controller c;
	const struct ssc_description *d=&ssc_descriptions[7];
	struct uke_ssc_attributes a={.available=true,.physical=true,.stream_type=0,
		.rate_count=1,.rate={0x40a00000}};
	static const u8 positive[]={13,0,0,0xcc,0x41,16,3}; /* 25.5 Celsius */
	static const u8 negative[]={13,0,0,0x20,0xc0,16,3}; /* -2.5 Celsius */
	u8 sample[sizeof(positive)];
	struct uke_ssc_event e={.message=1025,.ticks=1,.payload={sample,sizeof(sample)}};
	s64 values[3]={};
	int val=77,val2=88;

	setup(&c);
	assert(d->kind==SSC_TEMPERATURE&&d->channel==IIO_TEMP&&d->dimensions==1);
	assert(!strcmp(d->datatype,"sensor_temperature")&&!strcmp(d->api,"sns_sensor_temperature.proto"));
	assert(ssc_attributes_usable(d,&a));
	a.stream_type=1;assert(!ssc_attributes_usable(d,&a));
	a.stream_type=0;a.rate_count=0;assert(!ssc_attributes_usable(d,&a));
	a.rate_count=1;a.physical=false;assert(!ssc_attributes_usable(d,&a));
	a.physical=true;a.available=false;assert(!ssc_attributes_usable(d,&a));
	a.available=true;a.hlos_incompatible=true;assert(!ssc_attributes_usable(d,&a));
	a.hlos_incompatible=false;assert(ssc_attributes_usable(d,&a));
	assert(ssc_read_scale(d,&val,&val2)==IIO_VAL_INT&&val==1&&val2==0);
	assert(ssc_read_scale(&ssc_descriptions[0],&val,&val2)==IIO_VAL_INT_PLUS_MICRO&&val==0&&val2==1);
	assert(ssc_read_scale(&ssc_descriptions[2],&val,&val2)==IIO_VAL_INT_PLUS_MICRO&&val==0&&val2==1);
	val=77;val2=88;assert(ssc_read_scale(&ssc_descriptions[5],&val,&val2)==-EINVAL&&val==77&&val2==88);
	memcpy(sample,positive,sizeof(sample));
	assert(!ssc_sample_values(&c.sensor[7],&e,values)&&values[0]==25500);
	memcpy(sample,negative,sizeof(sample));
	assert(!ssc_sample_values(&c.sensor[7],&e,values)&&values[0]==-2500);
	for(unsigned int status=0;status<3;status++) {
		sample[6]=status;assert(ssc_sample_values(&c.sensor[7],&e,values)==-EAGAIN);
	}
	memcpy(sample,positive,sizeof(sample));sample[3]=0xc0;sample[4]=0x7f;
	assert(ssc_sample_values(&c.sensor[7],&e,values)<0); /* NaN */
	e.payload=(struct uke_ssc_view){positive,sizeof(positive)-1};
	assert(ssc_sample_values(&c.sensor[7],&e,values)<0);
	e.message=769;assert(ssc_sample_values(&c.sensor[7],&e,values)==-ENOMSG);
}
int main(void)
{
	qmi_wire();ownership();large_discovery_metadata();reports();units_and_rates();temperature();
	observation_contract();discovery_failure_contract();
	puts("Actual native SSC: upstream QMI wire round trips, acknowledgements, client/peer/generation guards, request faults, socket cleanup, sample admission, error release and IIO units passed; fake providers only");
	return 0;
}
