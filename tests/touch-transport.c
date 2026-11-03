/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sched.h>

typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;
#define NVT_UKE_FRAME_SIZE 5432
#define NOTIFY_OK 1
#define NOTIFY_STOP 0x8001
#define NOTIFY_BAD 0x8002
#define UKE_O82_TOUCH_RETAIN 1
#define UKE_O82_TOUCH_RELEASE 2
#define POWER_SUPPLY_PROP_ONLINE 1
#define PSY_EVENT_PROP_CHANGED 1
#define container_of(p, t, m) ((t *)((char *)(p) - offsetof(t, m)))
typedef pthread_mutex_t mutex_t;
#define mutex_lock(m) assert(pthread_mutex_lock(m) == 0)
#define mutex_unlock(m) assert(pthread_mutex_unlock(m) == 0)
#define spin_lock_irqsave(m, f) do { (f) = 0; mutex_lock(m); } while (0)
#define spin_unlock_irqrestore(m, f) do { (void)(f); mutex_unlock(m); } while (0)
struct nvt_uke_touch;
struct device { struct nvt_uke_touch *touch; int kobj; };
struct spi_device { struct nvt_uke_touch *touch; int irq; struct device dev; };
struct firmware { const u8 *data; size_t size; };
struct work_struct { unsigned int pending; struct nvt_uke_touch *touch; };
struct delayed_work { unsigned int pending; };
struct nvt_uke_matrix { unsigned int samples; };
static unsigned long jiffies = 1234;
#define msecs_to_jiffies(ms) (ms)
struct notifier_block { int unused; };
struct nvt_uke_io { void *context; };
struct vb2_queue { unsigned int done, errors; };
struct nvt_uke_touch {
    struct spi_device *spi;
    mutex_t ctrl, io_lock, irq_lock, state_lock;
    struct work_struct boot_work;
    struct work_struct charger_work;
    struct delayed_work poll_work;
    struct nvt_uke_matrix matrix;
    unsigned long last_irq, last_valid;
    struct notifier_block panel_notifier;
    struct notifier_block supply_notifier;
    struct nvt_uke_io io;
    struct vb2_queue queue;
    u64 epoch, transfer_epoch, panel_state;
    bool streaming, panel_ready, suspended, removed, fault;
    bool irq_enabled, booted, idle_reset;
    bool gesture_io, gesture_armed, irq_wake;
    bool firmware_ready;
    const struct firmware *firmware;
    bool charger_known, charger_online;
    unsigned int watchdog;
    u8 *tx, *rx;
};
struct spi_transfer {
    const void *tx_buf; void *rx_buf;
    unsigned int len, speed_hz, bits_per_word;
};
struct spi_message { struct spi_transfer *xfer; unsigned int actual_length; };
static void spi_message_init_with_transfers(struct spi_message *m, struct spi_transfer *x, unsigned int n) {
    assert(n == 1); m->xfer = x;
}
static struct {
    unsigned int calls, fail, short_at, change_epoch, enables, disables, cancels, queues;
    unsigned int lengths[2], speeds[2];
    unsigned int charger_calls, psy_gets, warnings;
    int charger_error, psy_error, online, psy_refs;
    bool psy_missing;
    bool wake_allowed;
    int wake_enable_error, wake_disable_error, boot_error, gesture_error;
    unsigned int wake_enables, wake_disables, boots, gestures, coordinates, releases;
    int coordinate_error;
    u8 bytes[2][NVT_UKE_FRAME_SIZE + 2];
    bool block, entered, proceed;
    pthread_mutex_t lock;
    pthread_cond_t cond;
} mock = { .lock = PTHREAD_MUTEX_INITIALIZER, .cond = PTHREAD_COND_INITIALIZER };

static int spi_sync(struct spi_device *spi, struct spi_message *m) {
    struct spi_transfer *x = m->xfer;
    unsigned int index = mock.calls++;
    assert(index < 2 && x->bits_per_word == 8);
    mock.lengths[index] = x->len; mock.speeds[index] = x->speed_hz;
    memcpy(mock.bytes[index], x->tx_buf, x->len);
    if (x->rx_buf)
        for (unsigned int i = 0; i < x->len; ++i) ((u8 *)x->rx_buf)[i] = (u8)i;
    if (mock.change_epoch == mock.calls) {
        mutex_lock(&spi->touch->state_lock);
        spi->touch->epoch++;
        mutex_unlock(&spi->touch->state_lock);
    }
    if (mock.block) {
        mutex_lock(&mock.lock);
        mock.entered = true;
        assert(pthread_cond_broadcast(&mock.cond) == 0);
        while (!mock.proceed) assert(pthread_cond_wait(&mock.cond, &mock.lock) == 0);
        mutex_unlock(&mock.lock);
    }
    if (mock.fail == mock.calls) return -EREMOTEIO;
    m->actual_length = x->len - (mock.short_at == mock.calls);
    return 0;
}
static void enable_irq(int irq) { assert(irq == 54); mock.enables++; }
static void disable_irq(int irq) { assert(irq == 54); mock.disables++; }
static int enable_irq_wake(int irq) { assert(irq == 54); mock.wake_enables++; return mock.wake_enable_error; }
static int disable_irq_wake(int irq) { assert(irq == 54); mock.wake_disables++; return mock.wake_disable_error; }
static bool device_may_wakeup(struct device *dev) { return mock.wake_allowed; }
static void sysfs_notify(void *kobj, const char *dir, const char *name) {
    assert(!dir && !strcmp(name, "gesture_wake_armed"));
}
#define dev_warn(...) do { mock.warnings++; } while (0)
#define dev_err(...) do { mock.warnings++; } while (0)
static void cancel_work_sync(struct work_struct *w) {
    assert(!w->touch->irq_enabled);
    mock.cancels++; w->pending = 0;
}
static void *system_long_wq;
static void queue_work(void *queue, struct work_struct *w) { mock.queues++; w->pending = 1; }
static void mod_delayed_work(void *queue, struct delayed_work *w, unsigned long delay) {
    assert(queue == system_long_wq && delay == 20);w->pending = 1;
}
static void cancel_delayed_work_sync(struct delayed_work *w) { w->pending = 0; }
static void nvt_uke_matrix_reset(struct nvt_uke_matrix *m) { m->samples = 0; }
static void *dev_get_drvdata(struct device *dev) { return dev->touch; }
struct power_supply_desc { const char *name; };
struct power_supply { const struct power_supply_desc *desc; };
union power_supply_propval { int intval; };
static struct power_supply_desc psy_desc = { .name = "qcom-battmgr-usb" };
static struct power_supply psy = { .desc = &psy_desc };
static struct power_supply *power_supply_get_by_name(const char *name) {
    assert(strcmp(name, "qcom-battmgr-usb") == 0); mock.psy_gets++;
    if (mock.psy_missing) return NULL;
    mock.psy_refs++; return &psy;
}
static int power_supply_get_property(struct power_supply *s, int prop, union power_supply_propval *v) {
    assert(s == &psy && prop == POWER_SUPPLY_PROP_ONLINE && mock.psy_refs == 1);
    v->intval = mock.online; return mock.psy_error;
}
static void power_supply_put(struct power_supply *s) { assert(s == &psy); mock.psy_refs--; }
static int nvt_ready(void *context);
static int nvt_uke_boot(const struct nvt_uke_io *io, const u8 *data, size_t size, bool idle) {
    assert(!nvt_ready(io->context) && !idle); mock.boots++; return mock.boot_error;
}
static int nvt_uke_gesture_enter(const struct nvt_uke_io *io) {
    assert(!nvt_ready(io->context)); mock.gestures++; return mock.gesture_error;
}
static void nvt_release_contacts(struct nvt_uke_touch *t) {
    assert(t == t->spi->touch); mock.releases++;
}
static int nvt_uke_coordinate_mode(const struct nvt_uke_io *io, bool enabled) {
    assert(!nvt_ready(io->context) && !enabled); mock.coordinates++;
    return mock.coordinate_error;
}
static int nvt_uke_charger(const struct nvt_uke_io *io, bool online) {
    assert(nvt_ready(io->context) == 0 && online == mock.online);
    mock.charger_calls++; return mock.charger_error;
}
#define dev_warn_ratelimited(...) do { mock.warnings++; } while (0)
#define dev_err_ratelimited(...) do { mock.warnings++; } while (0)

#include "production.h"

static struct nvt_uke_touch touch;
static struct spi_device spi = { .touch = &touch, .irq = 54 };
static u8 tx[NVT_UKE_FRAME_SIZE + 2], rx[NVT_UKE_FRAME_SIZE + 2];
static const struct firmware firmware;

static void reset(void) {
    touch.epoch = touch.transfer_epoch = 1;
    touch.streaming = touch.panel_ready = true;
    touch.suspended = touch.removed = touch.fault = false;
    touch.irq_enabled = false; touch.booted = true;
    touch.firmware_ready = true;
    touch.gesture_io = touch.gesture_armed = touch.irq_wake = false;
    touch.firmware = &firmware;
    touch.charger_known = touch.charger_online = false;
    touch.panel_state = 1; touch.watchdog = 10; touch.idle_reset = true;
    touch.boot_work.pending = 0;
    touch.charger_work.pending = 0;
    touch.poll_work.pending = 0;touch.matrix.samples = 32;
    mock.calls = mock.fail = mock.short_at = mock.change_epoch = 0;
    mock.enables = mock.disables = mock.cancels = mock.queues = 0;
    mock.charger_calls = mock.psy_gets = mock.warnings = 0;
    mock.charger_error = mock.psy_error = mock.psy_refs = 0;
    mock.online = 1; mock.psy_missing = false;
    mock.wake_allowed = false;
    mock.wake_enable_error = mock.wake_disable_error = mock.boot_error = mock.gesture_error = 0;
    mock.wake_enables = mock.wake_disables = mock.boots = mock.gestures = 0;
    mock.coordinates = mock.releases = 0; mock.coordinate_error = 0;
    mock.block = mock.entered = mock.proceed = false;
}

static int race_result;
static void *transfer_thread(void *unused) {
    u8 data[6];
    mutex_lock(&touch.io_lock);
    race_result = nvt_spi_io(&touch, 0x11c000, data, sizeof(data), true, true);
    mutex_unlock(&touch.io_lock);
    return NULL;
}
static void *panel_thread(void *unused) {
    u64 state = 2;
    assert(nvt_panel_changed(&touch.panel_notifier, 0, &state) == NOTIFY_OK);
    return NULL;
}

int main(void) {
    assert(pthread_mutex_init(&touch.ctrl, NULL) == 0);
    assert(pthread_mutex_init(&touch.io_lock, NULL) == 0);
    assert(pthread_mutex_init(&touch.irq_lock, NULL) == 0);
    assert(pthread_mutex_init(&touch.state_lock, NULL) == 0);
    touch.spi = &spi; touch.tx = tx; touch.rx = rx; touch.boot_work.touch = &touch;
    touch.charger_work.touch = &touch; touch.io.context = &touch;
    reset();
    u8 data[NVT_UKE_FRAME_SIZE];
    assert(nvt_spi_io(&touch, 0x11c000, data, sizeof(data), true, true) == 0);
    assert(mock.calls == 2 && mock.lengths[0] == 3 && mock.lengths[1] == 5434);
    assert(mock.bytes[0][0] == 0xff && mock.bytes[0][1] == (u8)(0x11c000 >> 15));
    assert(mock.bytes[0][2] == (u8)(0x11c000 >> 7) && mock.bytes[1][0] == 0);
    assert(mock.speeds[0] == 1000000 && mock.speeds[1] == 19200000);
    for (unsigned int i = 0; i < sizeof(data); ++i) assert(data[i] == (u8)(i + 2));
    reset(); memset(data, 0xa5, sizeof(data));
    assert(nvt_spi_io(&touch, 0x100001, data, 1024, false, true) == 0);
    assert(mock.lengths[1] == 1025 && mock.bytes[1][0] == 0x81);
    assert(memcmp(mock.bytes[1] + 1, data, 1024) == 0);
    reset();
    assert(nvt_spi_io(&touch, 0, NULL, 1, true, false) == -EINVAL);
    assert(nvt_spi_io(&touch, 0, data, 0, true, false) == -EINVAL);
    assert(nvt_spi_io(&touch, 0, data, sizeof(data) + 1, true, false) == -EINVAL);
    assert(nvt_spi_io(&touch, 0x1000000, data, 1, true, false) == -EINVAL);
    assert(nvt_spi_io(&touch, 0xffffff, data, 2, true, false) == -EINVAL);
    assert(mock.calls == 0);
    for (unsigned int step = 1; step <= 2; ++step) {
        reset(); mock.fail = step;
        assert(nvt_spi_io(&touch, 0x11c000, data, sizeof(data), true, true) == -EREMOTEIO);
        assert(mock.calls == step);
        reset(); mock.short_at = step;
        assert(nvt_spi_io(&touch, 0x11c000, data, sizeof(data), true, true) == -EIO);
        assert(mock.calls == step);
        reset(); mock.change_epoch = step;
        assert(nvt_spi_io(&touch, 0x11c000, data, sizeof(data), true, true) == -ESHUTDOWN);
        assert(mock.calls == step);
    }
    for (unsigned int bits = 0; bits < 32; ++bits) {
        reset(); touch.streaming = bits & 1; touch.panel_ready = bits & 2;
        touch.suspended = bits & 4; touch.removed = bits & 8; touch.fault = bits & 16;
        assert((nvt_ready(&touch) == 0) == (bits == 2 || bits == 3));
        touch.epoch++;
        assert(nvt_ready(&touch) == -ESHUTDOWN);
    }
    reset(); touch.epoch++;
    nvt_irq_set(&touch, true); assert(mock.enables == 0);
    touch.transfer_epoch = touch.epoch;
    nvt_irq_set(&touch, true); nvt_irq_set(&touch, true);
    assert(mock.enables == 1);
    u64 state = 3;
    assert(nvt_panel_changed(&touch.panel_notifier, 0, &state) == NOTIFY_OK);
    assert(mock.disables == 1 && mock.cancels == 2 && mock.queues == 1);
    assert(!touch.booted && !touch.idle_reset && !touch.watchdog);
    nvt_irq_set(&touch, true); assert(mock.enables == 1);
    assert(nvt_panel_changed(&touch.panel_notifier, 0, &state) == NOTIFY_OK);
    assert(mock.cancels == 2 && mock.queues == 1);
    struct device dev = { .touch = &touch };
    assert(nvt_suspend(&dev) == 0 && touch.suspended);
    assert(nvt_resume(&dev) == 0 && !touch.suspended && mock.queues == 2);
    state = 4;
    assert(nvt_panel_changed(&touch.panel_notifier, 0, &state) == NOTIFY_OK);
    assert(nvt_suspend(&dev) == 0 && nvt_resume(&dev) == 0 && mock.queues == 2);
    touch.removed = true; state = 5;
    assert(nvt_panel_changed(&touch.panel_notifier, 0, &state) == NOTIFY_OK);
    assert(mock.queues == 2);

    reset(); touch.panel_ready = false;
    nvt_charger_worker(&touch.charger_work);
    assert(mock.psy_gets == 0 && mock.charger_calls == 0);
    touch.panel_ready = true;
    nvt_charger_worker(&touch.charger_work);
    assert(mock.charger_calls == 1 && touch.charger_known && touch.charger_online);
    nvt_charger_worker(&touch.charger_work);
    assert(mock.charger_calls == 1 && mock.psy_refs == 0);
    mock.online = 0;
    nvt_charger_worker(&touch.charger_work);
    assert(mock.charger_calls == 2 && !touch.charger_online);
    mock.online = 1; mock.charger_error = -EBADMSG;
    nvt_charger_worker(&touch.charger_work);
    assert(mock.charger_calls == 3 && !touch.charger_online && mock.warnings == 1);
    mock.psy_error = -ENODATA;
    nvt_charger_worker(&touch.charger_work);
    assert(mock.charger_calls == 3 && mock.psy_refs == 0);
    mock.psy_error = 0; mock.online = 2;
    nvt_charger_worker(&touch.charger_work);
    assert(mock.charger_calls == 3 && mock.psy_refs == 0);
    mock.psy_missing = true;
    nvt_charger_worker(&touch.charger_work);
    assert(mock.charger_calls == 3 && mock.psy_refs == 0);
    assert(nvt_supply_changed(&touch.supply_notifier, 0, &psy) == NOTIFY_OK);
    assert(mock.queues == 0);
    assert(nvt_supply_changed(&touch.supply_notifier, PSY_EVENT_PROP_CHANGED, &psy) == NOTIFY_OK);
    assert(mock.queues == 1);

    /* Gesture retention is independent of raw streaming and arms wake once. */
    reset(); mock.wake_allowed=true; touch.streaming=false;
    u64 gesture_state=0;
    assert(nvt_panel_changed(&touch.panel_notifier,0,&gesture_state)==NOTIFY_OK);
    assert(!touch.panel_ready && !touch.booted && touch.firmware_ready);
    assert(nvt_panel_changed(&touch.panel_notifier,UKE_O82_TOUCH_RETAIN,&gesture_state)==NOTIFY_STOP);
    assert(mock.boots==0 && mock.gestures==1 && touch.gesture_armed && touch.irq_enabled);
    assert(!nvt_ready(&touch));
    struct device gesture_device={.touch=&touch};
    mock.wake_enable_error=-EIO;
    assert(nvt_suspend(&gesture_device)==-EIO && !touch.suspended && !touch.irq_wake);
    mock.wake_enable_error=0;
    assert(!nvt_suspend(&gesture_device) && touch.irq_wake && touch.irq_enabled);
    assert(nvt_ready(&touch)==-ESHUTDOWN);
    mock.wake_disable_error=-EIO;
    assert(nvt_resume(&gesture_device)==-EIO && touch.suspended && touch.irq_wake);
    const unsigned int arms=mock.wake_enables;
    assert(nvt_suspend(&gesture_device)==-EBUSY && mock.wake_enables==arms);
    mock.wake_disable_error=0;
    assert(!nvt_resume(&gesture_device) && !touch.irq_wake && !nvt_ready(&touch));
    assert(nvt_panel_changed(&touch.panel_notifier,UKE_O82_TOUCH_RELEASE,&gesture_state)==NOTIFY_OK);
    assert(!touch.gesture_armed && !touch.gesture_io && !touch.irq_enabled);
    assert(!touch.firmware_ready);
    for(unsigned int failure=0;failure<2;failure++) {
        reset(); mock.wake_allowed=true; touch.panel_ready=false;
        if(failure) mock.gesture_error=-EPROTO; else touch.firmware_ready=false;
        assert(nvt_panel_changed(&touch.panel_notifier,UKE_O82_TOUCH_RETAIN,&gesture_state)==NOTIFY_BAD);
        assert(!touch.gesture_armed && !touch.gesture_io && !touch.irq_enabled);
        assert(!mock.boots && mock.gestures==failure);
    }
    reset(); touch.panel_ready=false;
    assert(nvt_panel_changed(&touch.panel_notifier,UKE_O82_TOUCH_RETAIN,&gesture_state)==NOTIFY_OK && !mock.boots);

    /* Only a completed normal boot can admit a later gesture transition. */
    reset(); touch.booted=touch.firmware_ready=false; touch.idle_reset=false;
    nvt_boot_worker(&touch.boot_work);
    assert(mock.boots==1 && mock.coordinates==1 && touch.booted && touch.firmware_ready && touch.irq_enabled);
    assert(touch.poll_work.pending && touch.matrix.samples == 0);
    touch.removed = true;
    nvt_quiesce(&touch);
    assert(!touch.poll_work.pending);
    nvt_schedule_poll(&touch);
    assert(!touch.poll_work.pending);
    reset();touch.idle_reset=false;
    nvt_boot_worker(&touch.boot_work);
    mock.boot_error=-EIO;
    nvt_boot_worker(&touch.boot_work);
    assert(mock.boots==2 && !touch.booted && !touch.firmware_ready && touch.fault);
    reset(); touch.idle_reset=false; mock.coordinate_error=-EPROTO;
    nvt_boot_worker(&touch.boot_work);
    assert(mock.boots==1 && mock.coordinates==1 && touch.fault && !touch.booted && !touch.irq_enabled);
    reset(); touch.panel_ready=false;
    nvt_boot_worker(&touch.boot_work);
    assert(!mock.boots && !touch.booted && !touch.firmware_ready && !touch.fault);
    reset();
    assert(!nvt_suspend(&gesture_device) && !touch.firmware_ready);

    /* The real panel callback must drain a transfer before reset may proceed. */
    for (unsigned int iteration = 0; iteration < 100; ++iteration) {
        reset(); mock.block = true;
        pthread_t transfer, panel;
        assert(pthread_create(&transfer, NULL, transfer_thread, NULL) == 0);
        mutex_lock(&mock.lock);
        while (!mock.entered) assert(pthread_cond_wait(&mock.cond, &mock.lock) == 0);
        mutex_unlock(&mock.lock);
        assert(pthread_create(&panel, NULL, panel_thread, NULL) == 0);
        while (true) {
            mutex_lock(&touch.state_lock);
            bool invalidated = !touch.panel_ready;
            mutex_unlock(&touch.state_lock);
            if (invalidated) break;
            sched_yield();
        }
        mutex_lock(&mock.lock);
        mock.proceed = true; assert(pthread_cond_broadcast(&mock.cond) == 0);
        mutex_unlock(&mock.lock);
        assert(pthread_join(transfer, NULL) == 0 && pthread_join(panel, NULL) == 0);
        assert(race_result == -ESHUTDOWN && mock.calls == 1);
        assert(!touch.panel_ready && !touch.booted && !touch.irq_enabled);
    }
    puts("Production SPI framing/faults, state admission, IRQ epochs and 100 in-flight panel races: PASS");
    return 0;
}
