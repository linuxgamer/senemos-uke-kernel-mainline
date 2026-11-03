#!/usr/bin/env bash
# Actual QRTR worker, transport publication and name-server paths; host memory only.
# shellcheck disable=SC2129
set -euo pipefail
kernel=${1:?Pass prepared kernel source}
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
core=$kernel/net/qrtr/af_qrtr.c
smd=$kernel/net/qrtr/smd.c
ns=$kernel/net/qrtr/ns.c
cat > "$stage/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#define AF_QIPCRTR 42
#define QRTR_PORT_CTRL 0xfffffffeU
#define QRTR_TYPE_HELLO 2
#define QRTR_EP_NID_AUTO (-1)
#define GFP_KERNEL 0
#define READ_ONCE(x) (x)
#define cpu_to_le32(x) (x)
#define container_of(p,t,m) ((t *)((char *)(p)-offsetof(t,m)))
#define to_delayed_work(p) container_of(p,struct delayed_work,work)
#define EXPORT_SYMBOL_GPL(x)
#define dev_dbg(...) ((void)0)
#define pr_err(...) ((void)0)
struct work_struct {int unused;};
struct delayed_work {struct work_struct work;};
struct sockaddr_qrtr {unsigned sq_family,sq_node,sq_port;};
struct qrtr_server {unsigned node;};
struct qrtr_endpoint;
struct qrtr_node {int ep_lock;struct qrtr_endpoint *ep;unsigned nid;struct delayed_work say_hello;int servers;};
struct qrtr_endpoint {struct qrtr_node *node;int (*xmit)(struct qrtr_endpoint *,void *);};
struct qrtr_sock {int unused;};
struct qrtr_ctrl_pkt {unsigned cmd;};
struct sk_buff {struct qrtr_ctrl_pkt packet;};
static struct qrtr_node node;
static struct qrtr_sock control;
static struct sk_buff buffer;
static unsigned qrtr_local_nid=1,scheduled,delay,sends,put_count,locks,announcements;
static bool ns_ready,alloc_fail,device_alloc_fail,checking_receive;
static void check_receive_context(void);
static int send_result,register_error;
static void mutex_lock(int *p){assert(p==&node.ep_lock && !locks++);}
static void mutex_unlock(int *p){assert(p==&node.ep_lock && locks--==1);}
static int schedule_delayed_work(struct delayed_work *work,unsigned ms)
{assert(work==&node.say_hello);if(!ms&&checking_receive)check_receive_context();scheduled++;delay=ms;return 1;}
static unsigned msecs_to_jiffies(unsigned ms){return ms;}
static struct qrtr_sock *qrtr_port_lookup(unsigned port)
{assert(port==QRTR_PORT_CTRL);return ns_ready?&control:NULL;}
static void qrtr_port_put(struct qrtr_sock *sock){assert(sock==&control);put_count++;}
static struct sk_buff *qrtr_alloc_ctrl_packet(struct qrtr_ctrl_pkt **p,int flags)
{assert(flags==GFP_KERNEL);if(alloc_fail)return NULL;*p=&buffer.packet;return &buffer;}
static int qrtr_node_enqueue(struct qrtr_node *n,struct sk_buff *b,int type,
 struct sockaddr_qrtr *from,struct sockaddr_qrtr *to)
{assert(n==&node && b==&buffer && type==QRTR_TYPE_HELLO && !locks);
 assert(b->packet.cmd==QRTR_TYPE_HELLO && from->sq_node==1 && to->sq_node==5);
 assert(from->sq_port==QRTR_PORT_CTRL && to->sq_port==QRTR_PORT_CTRL);
 sends++;return send_result;}
C
awk '/^static void qrtr_hello_work\(/ {emit=1} /^void qrtr_endpoint_hello\(/ {emit=1}
 emit {print} emit && /^}/ {emit=0}' "$core" >> "$stage/check.c"
cat >> "$stage/check.c" <<'C'
struct device {void *data;};
struct rpmsg_device {struct device dev;void *ept;};
struct qrtr_smd_dev {struct qrtr_endpoint ep;void *channel;struct device *dev;};
static struct qrtr_smd_dev storage;
static struct rpmsg_device *probing;
static void *devm_kzalloc(struct device *dev,size_t size,int flags)
{assert(dev==&probing->dev && size==sizeof(storage) && flags==GFP_KERNEL);
 memset(&storage,0,sizeof(storage));return device_alloc_fail?NULL:&storage;}
static int qcom_smd_qrtr_send(struct qrtr_endpoint *ep,void *skb){(void)ep;(void)skb;return 0;}
static int qrtr_endpoint_register(struct qrtr_endpoint *ep,int nid)
{assert(ep==&storage.ep && ep->xmit==qcom_smd_qrtr_send && nid==QRTR_EP_NID_AUTO);
 assert(storage.channel==probing->ept && storage.dev==&probing->dev);
 ep->node=&node;return register_error;}
static void dev_set_drvdata(struct device *dev,void *data){dev->data=data;}
static void check_receive_context(void) {assert(probing->dev.data==&storage);}
C
awk '/^static int qcom_smd_qrtr_probe\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$smd" >> "$stage/check.c"
cat >> "$stage/check.c" <<'C'
struct list_head {int index;};
struct qrtr_lookup {struct list_head li;unsigned service,instance;struct sockaddr_qrtr sq;};
static struct qrtr_lookup lookups[3];
static unsigned notifications;
static struct {unsigned local_node;struct sockaddr_qrtr bcast_sq;struct list_head lookups;} qrtr_ns={.local_node=1};
static struct qrtr_server servers[3];
static struct qrtr_node *node_get(unsigned id){assert(id==1);return &node;}
#define xa_for_each(array,index,srv) for((index)=0;(index)<3 && ((srv)=&servers[index]);(index)++)
static int service_announce_new(struct sockaddr_qrtr *sq,struct qrtr_server *srv)
{if(sq==&qrtr_ns.bcast_sq)return -EAGAIN;
 assert(srv==&servers[announcements++]);return announcements==1?-EAGAIN:0;}
static struct qrtr_server *server_add(unsigned service,unsigned instance,unsigned nid,unsigned port)
{assert(service==64 && instance==1 && nid==1 && port==100);servers[0].node=nid;return &servers[0];}
#define list_for_each(li,head) for(unsigned i=0; i<3 && ((li)=&lookups[i].li);i++)
static void lookup_notify(struct sockaddr_qrtr *sq,struct qrtr_server *srv,bool add)
{assert(srv==&servers[0] && add && (sq==&lookups[0].sq || sq==&lookups[1].sq));notifications++;}
C
awk '/^static int announce_servers\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$ns" >> "$stage/check.c"
awk '/^static int ctrl_cmd_hello\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$ns" >> "$stage/check.c"
awk '/^static int ctrl_cmd_new_server\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$ns" >> "$stage/check.c"
cat >> "$stage/check.c" <<'C'
static void reset(void)
{memset(&node,0,sizeof(node));node.nid=5;node.ep=&storage.ep;
 scheduled=delay=sends=put_count=locks=0;ns_ready=true;alloc_fail=false;send_result=0;}
int main(void)
{
 reset();ns_ready=false;qrtr_hello_work(&node.say_hello.work);
 assert(scheduled==1 && delay==100 && !sends && !put_count && !locks);
 reset();alloc_fail=true;qrtr_hello_work(&node.say_hello.work);
 assert(scheduled==1 && delay==100 && !sends && put_count==1 && !locks);
 const int results[]={0,-EAGAIN,-ENOMEM,-ETIMEDOUT,-ENODEV,-EIO,-ECANCELED};
 for(unsigned i=0;i<sizeof(results)/sizeof(results[0]);i++) {
  reset();send_result=results[i];qrtr_hello_work(&node.say_hello.work);
  assert(sends==1 && put_count==1 && !locks);
  assert(scheduled==(send_result==-EAGAIN || send_result==-ENOMEM || send_result==-ETIMEDOUT));
  if(scheduled)assert(delay==100);
 }
 reset();node.ep=NULL;ns_ready=false;qrtr_hello_work(&node.say_hello.work);
 assert(!scheduled && !sends && !put_count && !locks);
 reset();struct qrtr_endpoint ep={.node=&node};qrtr_endpoint_hello(&ep);
 assert(scheduled==1 && !delay);
 struct rpmsg_device dev={.ept=&buffer};probing=&dev;
 reset();dev.dev.data=NULL;register_error=0;device_alloc_fail=false;checking_receive=true;
 assert(!qcom_smd_qrtr_probe(&dev) && dev.dev.data==&storage);
 assert(scheduled==1 && !delay);
 checking_receive=false;
 reset();register_error=-EIO;dev.dev.data=NULL;
 assert(qcom_smd_qrtr_probe(&dev)==-EIO && !scheduled && !dev.dev.data);
 register_error=0;device_alloc_fail=true;
 assert(qcom_smd_qrtr_probe(&dev)==-ENOMEM && !scheduled && !dev.dev.data);
 struct sockaddr_qrtr dest={0};announcements=0;
 assert(!announce_servers(&dest) && announcements==3);
 announcements=0;assert(!ctrl_cmd_hello(&dest) && announcements==3);
 dest.sq_node=1;dest.sq_port=100;lookups[1].service=64;lookups[2].service=400;
 assert(ctrl_cmd_new_server(&dest,64,1,99,99)==-EAGAIN && notifications==2);
 puts("Actual QRTR HELLO: receive publication, readiness/allocation/timeout retries, permanent failure/teardown, peer HELLO replay and preserved lookup notifications passed. Host only.");
}
C
"${CC:-cc}" -std=gnu11 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -fno-omit-frame-pointer "$stage/check.c" -o "$stage/check"
"$stage/check"
cat > "$stage/transports.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#define GFP_KERNEL 0
#define QRTR_EP_NID_AUTO (-1)
#define __maybe_unused
#define dev_dbg(...) ((void)0)
#define dev_err(...) ((void)0)
#define container_of(p,t,m) ((t *)((char *)(p)-offsetof(t,m)))
struct device {void *data;};
struct mhi_device {struct device dev;void *mhi_cntrl;};
struct mhi_device_id {int unused;};
struct qrtr_endpoint {int (*xmit)(struct qrtr_endpoint *,void *);};
struct qrtr_mhi_dev {struct qrtr_endpoint ep;struct mhi_device *mhi_dev;struct device *dev;};
struct sk_buff_head {bool ready;};
typedef struct {bool ready;} wait_queue_head_t;
struct qrtr_tun {struct qrtr_endpoint ep;struct sk_buff_head queue;wait_queue_head_t readq;};
struct inode {int unused;};
struct file {void *private_data;};
enum mhi_state {MHI_STATE_M0,MHI_STATE_M3};
static struct qrtr_mhi_dev mhi_storage;
static struct qrtr_tun tun_storage;
static struct mhi_device mdev;
static struct file file;
static enum mhi_state state;
static bool allocation_fail,registered,dl_ready,tun_test;
static int prepare_error,register_error,queue_error;
static unsigned prepares,unprepares,unregisters,hellos,frees;
static void *devm_kzalloc(struct device *d,size_t n,int flags)
{assert(d==&mdev.dev && n==sizeof(mhi_storage) && flags==GFP_KERNEL);
 return allocation_fail?NULL:&mhi_storage;}
static void dev_set_drvdata(struct device *d,void *p){d->data=p;}
static void *dev_get_drvdata(struct device *d){return d->data;}
static int qcom_mhi_qrtr_send(struct qrtr_endpoint *ep,void *skb){(void)ep;(void)skb;return 0;}
static int qrtr_tun_send(struct qrtr_endpoint *ep,void *skb){(void)ep;(void)skb;return 0;}
static int mhi_prepare_for_transfer(struct mhi_device *d)
{assert(d==&mdev && d->dev.data==&mhi_storage);prepares++;return prepare_error;}
static void mhi_unprepare_from_transfer(struct mhi_device *d)
{assert(d==&mdev);unprepares++;}
static int qrtr_endpoint_register(struct qrtr_endpoint *ep,int nid)
{assert(nid==QRTR_EP_NID_AUTO);
 if(tun_test)assert(ep==&tun_storage.ep && ep->xmit==qrtr_tun_send && file.private_data==&tun_storage);
 else assert(ep==&mhi_storage.ep && ep->xmit==qcom_mhi_qrtr_send && mhi_storage.mhi_dev==&mdev);
 registered=!register_error;return register_error;}
static void qrtr_endpoint_unregister(struct qrtr_endpoint *ep)
{assert(ep==&mhi_storage.ep && registered);registered=false;unregisters++;}
static int qcom_mhi_qrtr_queue_dl_buffers(struct mhi_device *d)
{assert(d==&mdev && registered);dl_ready=!queue_error;return queue_error;}
static enum mhi_state mhi_get_mhi_state(void *controller)
{assert(controller==&mdev);return state;}
static void qrtr_endpoint_hello(struct qrtr_endpoint *ep)
{assert(registered);
 if(tun_test)assert(ep==&tun_storage.ep && file.private_data==&tun_storage && tun_storage.queue.ready && tun_storage.readq.ready);
 else assert(ep==&mhi_storage.ep && mdev.dev.data==&mhi_storage && dl_ready);
 hellos++;}
#define kzalloc_obj(obj) (allocation_fail?NULL:&tun_storage)
static void skb_queue_head_init(struct sk_buff_head *q){q->ready=true;}
static void init_waitqueue_head(wait_queue_head_t *q){q->ready=true;}
static void kfree(void *p){assert(p==&tun_storage);frees++;}
C
awk '/^static int qcom_mhi_qrtr_probe\(/ {emit=1}
 /^static int __maybe_unused qcom_mhi_qrtr_pm_resume_early\(/ {emit=1}
 emit {print} emit && /^}/ {emit=0}' "$kernel/net/qrtr/mhi.c" >> "$stage/transports.c"
awk '/^static int qrtr_tun_open\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$kernel/net/qrtr/tun.c" >> "$stage/transports.c"
cat >> "$stage/transports.c" <<'C'
static void reset(void)
{memset(&mhi_storage,0,sizeof(mhi_storage));memset(&tun_storage,0,sizeof(tun_storage));
 memset(&mdev,0,sizeof(mdev));memset(&file,0,sizeof(file));mdev.mhi_cntrl=&mdev;
 state=MHI_STATE_M0;allocation_fail=registered=dl_ready=tun_test=false;
 prepare_error=register_error=queue_error=0;prepares=unprepares=unregisters=hellos=frees=0;}
int main(void)
{
 reset();assert(!qcom_mhi_qrtr_probe(&mdev,NULL) && hellos==1 && prepares==1);
 reset();allocation_fail=true;assert(qcom_mhi_qrtr_probe(&mdev,NULL)==-ENOMEM && !hellos && !prepares);
 reset();prepare_error=-EIO;assert(qcom_mhi_qrtr_probe(&mdev,NULL)==-EIO && !hellos && !unprepares);
 reset();register_error=-EIO;assert(qcom_mhi_qrtr_probe(&mdev,NULL)==-EIO && !hellos && unprepares==1 && !unregisters);
 reset();queue_error=-ENOMEM;assert(qcom_mhi_qrtr_probe(&mdev,NULL)==-ENOMEM && !hellos && unprepares==1 && unregisters==1);
 reset();assert(!qcom_mhi_qrtr_probe(&mdev,NULL));hellos=prepares=0;dl_ready=false;
 assert(!qcom_mhi_qrtr_pm_resume_early(&mdev.dev) && hellos==1 && prepares==1);
 hellos=prepares=0;state=MHI_STATE_M3;
 assert(!qcom_mhi_qrtr_pm_resume_early(&mdev.dev) && !hellos && !prepares);
 state=MHI_STATE_M0;prepare_error=-EIO;
 assert(qcom_mhi_qrtr_pm_resume_early(&mdev.dev)==-EIO && !hellos);
 prepare_error=0;queue_error=-ENOMEM;
 assert(qcom_mhi_qrtr_pm_resume_early(&mdev.dev)==-ENOMEM && !hellos);
 reset();tun_test=true;assert(!qrtr_tun_open(NULL,&file) && hellos==1 && !frees);
 reset();tun_test=true;allocation_fail=true;
 assert(qrtr_tun_open(NULL,&file)==-ENOMEM && !hellos && !file.private_data && !frees);
 reset();tun_test=true;register_error=-EIO;
 assert(qrtr_tun_open(NULL,&file)==-EIO && !hellos && !file.private_data && frees==1);
 puts("Actual QRTR MHI probe/resume and TUN open: receive readiness, M3 preservation and allocation/registration/prepare/queue failures passed. Host only.");
}
C
"${CC:-cc}" -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter \
    -fsanitize=address,undefined -fno-omit-frame-pointer "$stage/transports.c" -o "$stage/transports"
"$stage/transports"
# Only the core sends HELLO; accepted packet flow stays ungated.
if grep -q 'say_hello' "$ns"; then exit 1; fi
if grep -q 'hello_sent\|tx_backlog' "$core"; then exit 1; fi
awk '/^void qrtr_endpoint_unregister\(/ {emit=1}
 emit && /cancel_delayed_work_sync/ {cancel=1}
 emit && /qrtr_node_release\(node\)/ {exit !cancel}
 END {if (!emit) exit 1}' "$core"
