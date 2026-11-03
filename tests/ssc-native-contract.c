// SPDX-License-Identifier: GPL-2.0-only
/* Included after the actual production definitions/callbacks. No real providers. */
static struct {
	int init_error,send_error,protobuf_error;
	unsigned int live,cancelled,released,sent,pushed;
	bool no_ack,foreign,changed_client,stale_on_wait;
	unsigned int last_command;
	struct ssc_controller *controller;
	s64 pushed_value[3];
} fixture;

static int qmi_txn_init(struct qmi_handle *qmi, struct qmi_txn *txn, const void *ei, void *dest)
{
	(void)ei; (void)dest;
	assert(qmi->live);
	if (fixture.init_error) return fixture.init_error;
	*txn = (struct qmi_txn){ .qmi=qmi,.id=17 };
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
	assert(!IS_ERR(wire) && message == SSC_QMI_REQUEST && size == request->length + 12);
	assert(wire[0] == QMI_REQUEST && wire[3] == 0x20 && wire[7] == 1);
	assert((wire[10] | (unsigned int)wire[11] << 8) == request->length);
	assert(!memcmp(wire+12,request->payload,request->length));
	free(wire);
	fixture.last_command = request->payload[21] | (unsigned int)request->payload[22] << 8;
	fixture.sent++;
	if (fixture.send_error) return fixture.send_error;
	if (!fixture.no_ack) {
		if (fixture.foreign) sender.sq_node++;
		if (fixture.changed_client) response.client++;
		if (fixture.protobuf_error) { response.error_valid=1;response.error=fixture.protobuf_error; }
		ssc_response(qmi,&sender,txn,&response);
	}
	return 0;
}
static int qmi_txn_wait(struct qmi_txn *txn, unsigned long timeout)
{
	assert(timeout == SSC_TIMEOUT && fixture.live);
	fixture.live--;
	if (fixture.stale_on_wait) ssc_invalidate_locked(fixture.controller);
	return txn->completion.done ? txn->result : -ETIMEDOUT;
}
static void qmi_txn_cancel(struct qmi_txn *txn)
{
	(void)txn; assert(fixture.live);fixture.live--;fixture.cancelled++;
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
	u8 *wire=qmi_encode_message(QMI_RESPONSE,0x20,&size,17,ssc_response_ei,&source);
	assert(!IS_ERR(wire) && !qmi_decode_message(wire,size,ssc_response_ei,&decoded));
	assert(decoded.result_valid && decoded.client_valid && decoded.client==source.client && decoded.error_valid);
	free(wire);
	assert(in && out);in->client_valid=in->payload_valid=1;in->client=source.client;
	in->length=3;memcpy(in->payload,"abc",3);size=SSC_QMI_REPORT_MAX;
	wire=qmi_encode_message(QMI_INDICATION,0x21,&size,0,ssc_report_ei,in);
	assert(!IS_ERR(wire) && size==26 && !qmi_decode_message(wire,size,ssc_report_ei,out));
	assert(out->client_valid && out->payload_valid && out->length==3 && !memcmp(out->payload,"abc",3));
	assert(qmi_decode_message(wire,size-1,ssc_report_ei,out)<0);
	/* Body: client TLV11 bytes, payload TLV header3 bytes, little-endian length. */
	wire[21]=0xff;wire[22]=0xff;
	assert(qmi_decode_message(wire,size,ssc_report_ei,out)<0);
	free(wire);free(in);free(out);
}
struct fixture_bytes { u8 data[512];size_t size; };
static void put_le(struct fixture_bytes *b,u64 value,unsigned int size)
{ while(size--){assert(b->size<sizeof(b->data));b->data[b->size++]=value;value>>=8;} }
static void put_field(struct fixture_bytes *b,unsigned int field,const void *data,size_t size)
{ assert(size<128 && b->size+size+2<=sizeof(b->data));put_le(b,(field<<3)|2,1);put_le(b,size,1);if(size)memcpy(b->data+b->size,data,size);b->size+=size; }
static struct fixture_bytes event(unsigned int message,u64 ticks,const void *payload,size_t size)
{
	struct fixture_bytes b={},uid={},e={};
	put_le(&uid,9,1);put_le(&uid,0x123,8);put_le(&uid,17,1);put_le(&uid,0x456,8);
	put_field(&b,1,uid.data,uid.size);
	put_le(&e,13,1);put_le(&e,message,4);put_le(&e,17,1);put_le(&e,ticks,8);
	put_field(&e,3,payload,size);put_field(&b,2,e.data,e.size);return b;
}
static void reports(void)
{
	static const u8 xyz[]={13,0,0,0x80,0x3f,13,0,0,0x20,0xc0,13,0,0,0,0xbf,16,3};
	struct ssc_controller c;
	struct ssc_qmi_report *r=calloc(1,sizeof(*r));
	struct qmi_txn txn={};
	struct fixture_bytes b=event(1025,200,xyz,sizeof(xyz));
	assert(r);setup(&c);c.client_known=true;c.client_id=0x123456789ULL;
	c.sensor[0].declared=c.sensor[0].registered=c.sensor[0].buffered=c.sensor[0].stream_active=true;
	r->client_valid=r->payload_valid=1;r->client=c.client_id;r->length=b.size;memcpy(r->payload,b.data,b.size);
	ssc_report(&c.client,&c.peer,&txn,r);
	assert(fixture.pushed==1 && c.sensor[0].sample_sequence==10 && fixture.pushed_value[0]==1000000 && fixture.pushed_value[1]==-2500000);
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
int main(void)
{
	qmi_wire();ownership();reports();units_and_rates();
	puts("Actual native SSC: upstream QMI wire round trips, acknowledgements, client/peer/generation guards, request faults, socket cleanup, sample admission, error release and IIO units passed; fake providers only");
	return 0;
}
