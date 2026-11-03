/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef SSC_NATIVE_HOST_H
#define SSC_NATIVE_HOST_H
#include <assert.h>
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <linux/types.h>
#define U8_MAX UINT8_MAX
#define ETOOSMALL 525 /* Pinned Linux include/linux/errno.h; host-only shim. */
#define __packed __attribute__((packed))
#define __cpu_to_le16(x) (x)
#define __cpu_to_le32(x) (x)
#define __cpu_to_le64(x) (x)
#define __le16_to_cpu(x) (x)
#define __le32_to_cpu(x) (x)
#define __le64_to_cpu(x) (x)
#define cpu_to_le16(x) (x)
#define le16_to_cpu(x) (x)
#define cpu_to_le32(x) (x)
#define cpu_to_le64(x) (x)
#define le32_to_cpu(x) (x)
#define le64_to_cpu(x) (x)
#define EXPORT_SYMBOL_GPL(x)
#define MODULE_LICENSE(x)
#define MODULE_DESCRIPTION(x)
#define GFP_KERNEL 0
#define kzalloc(n,f) calloc(1,n)
#define kmalloc(n,f) malloc(n)
#define kfree(p) free(p)
#define ERR_PTR(n) ((void *)(intptr_t)(n))
#define IS_ERR(p) ((uintptr_t)(p) >= (uintptr_t)-4095)
#define PTR_ERR(p) ((intptr_t)(p))
#define pr_err(...) ((void)0)
#define container_of(p,t,m) ((t *)((char *)(p)-offsetof(t,m)))
#define AF_QIPCRTR 42
#define QRTR_PORT_CTRL 0xfffffffeU
#define msecs_to_jiffies(n) (n)
struct completion { unsigned int done; };
struct mutex { bool locked; };
typedef int spinlock_t;
struct qmi_txn;
struct qmi_idr { struct qmi_txn *txn; };
struct qmi_handle { bool live; struct mutex txn_lock; struct qmi_idr txns; };
struct qmi_txn { struct qmi_handle *qmi; u16 id; int result; struct completion completion; struct mutex lock; };
struct sockaddr_qrtr { unsigned short sq_family; u32 sq_node,sq_port; };
struct workqueue_struct { unsigned int queued; };
struct work_struct { int unused; };
struct list_head { struct list_head *next,*prev; };
struct device { int unused; };
struct iio_chan_spec { unsigned int unused; };
struct iio_dev { int unused; };
enum iio_chan_type { IIO_ACCEL,IIO_ANGL_VEL,IIO_MAGN,IIO_LIGHT,IIO_PROXIMITY,IIO_TEMP };
#define IIO_VAL_INT 1
#define IIO_VAL_INT_PLUS_MICRO 2
#define lockdep_assert_held(lock) assert((lock)->locked)
#define spin_lock_irqsave(lock,flags) do { (void)(lock); (flags)=0; } while(0)
#define spin_unlock_irqrestore(lock,flags) do { (void)(lock); (void)(flags); } while(0)
static inline void mutex_lock(struct mutex *m) { assert(!m->locked);m->locked=true; }
static inline void mutex_unlock(struct mutex *m) { assert(m->locked);m->locked=false; }
static inline struct qmi_txn *idr_find(struct qmi_idr *idr,unsigned int id)
{ return idr->txn && idr->txn->id==id ? idr->txn : NULL; }
static inline void complete(struct completion *c) { c->done++; }
static inline void complete_all(struct completion *c) { c->done=100; }
static inline void reinit_completion(struct completion *c) { c->done=0; }
static inline bool queue_work(struct workqueue_struct *q, struct work_struct *w)
{ (void)w; assert(q); q->queued++; return true; }
#ifdef UKE_SSC_NATIVE_CALLBACKS
static int qmi_txn_init(struct qmi_handle *,struct qmi_txn *,const void *,void *);
static int qmi_send_request(struct qmi_handle *,struct sockaddr_qrtr *,struct qmi_txn *,int,size_t,const void *,const void *);
static int qmi_txn_wait(struct qmi_txn *,unsigned long);
static void qmi_txn_cancel(struct qmi_txn *);
static void qmi_handle_release(struct qmi_handle *);
static int iio_push_to_buffers_with_ts(struct iio_dev *,void *,size_t,s64);
static s64 iio_get_time_ns(struct iio_dev *);
#endif
#endif
