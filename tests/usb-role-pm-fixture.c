// SPDX-License-Identifier: GPL-2.0-only
// Model external PM/MMIO facilities; include the production functions unchanged.
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

enum usb_role { USB_ROLE_NONE, USB_ROLE_HOST, USB_ROLE_DEVICE };
struct mutex { pthread_mutex_t native; };
struct device { void *data; };
struct dwc3 { struct device *dev; };
struct dwc3_qcom {
    struct dwc3 dwc;
    struct device device;
    struct device *dev;
    struct mutex role_lock;
    enum usb_role current_role;
    bool uke_typec, pm_suspended, vbus_override_pending, vbus_override;
};
#define to_dwc3_qcom(d) ((struct dwc3_qcom *)((char *)(d) - offsetof(struct dwc3_qcom, dwc)))
#define dev_dbg(...) ((void)0)
static struct {
    bool clocks_on, core_resumed, enabled, restore_gadget;
    unsigned writes, unsafe_writes, writes_after_core, gets, puts, protected_points;
    int runtime_error, core_suspend_error, glue_suspend_error;
    int glue_resume_error, core_resume_error;
} observed;

static bool lock_held(struct mutex *lock)
{
    int ret = pthread_mutex_trylock(&lock->native);
    if (!ret) {
        assert(!pthread_mutex_unlock(&lock->native));
        return false;
    }
    assert(ret == EBUSY);
    return true;
}
static __attribute__((unused)) struct mutex *guard_acquire(struct mutex *lock)
{
    assert(!pthread_mutex_lock(&lock->native));
    return lock;
}
static __attribute__((unused)) void guard_release(struct mutex **lock)
{
    assert(!pthread_mutex_unlock(&(*lock)->native));
}
#define guard(type) struct mutex *held __attribute__((cleanup(guard_release))) = guard_acquire
static void checked_boundary(struct dwc3_qcom *qcom)
{
    if (!EXPECT_BASELINE)
        assert(lock_held(&qcom->role_lock));
    observed.protected_points++;
}
static void *dev_get_drvdata(struct device *dev) { return dev->data; }
static bool device_may_wakeup(struct device *dev) { (void)dev; return true; }
static int pm_runtime_resume_and_get(struct device *dev)
{
    checked_boundary(to_dwc3_qcom(dev->data));
    observed.gets++;
    return observed.runtime_error;
}
static void pm_runtime_mark_last_busy(struct device *dev) { (void)dev; }
static void pm_runtime_put_sync(struct device *dev) { (void)dev; observed.puts++; }
static void dwc3_qcom_vbus_override_enable(struct dwc3_qcom *qcom, bool enabled)
{
    (void)qcom;
    observed.writes++;
    observed.unsafe_writes += !observed.clocks_on;
    observed.writes_after_core += observed.core_resumed;
    observed.enabled = enabled;
}
static int dwc3_pm_suspend(struct dwc3 *dwc)
{
    checked_boundary(to_dwc3_qcom(dwc));
    return observed.core_suspend_error;
}
static int dwc3_qcom_suspend(struct dwc3_qcom *qcom, bool wakeup)
{
    (void)wakeup;
    checked_boundary(qcom);
    if (observed.glue_suspend_error)
        return observed.glue_suspend_error;
    observed.clocks_on = observed.core_resumed = false;
    return 0;
}
static int dwc3_qcom_resume(struct dwc3_qcom *qcom, bool wakeup)
{
    (void)wakeup;
    checked_boundary(qcom);
    if (observed.glue_resume_error)
        return observed.glue_resume_error;
    observed.clocks_on = true;
    return 0;
}
static int dwc3_pm_resume(struct dwc3 *dwc)
{
    checked_boundary(to_dwc3_qcom(dwc));
    if (observed.restore_gadget)
        dwc3_qcom_vbus_override_enable(to_dwc3_qcom(dwc), true);
    observed.core_resumed = true;
    return observed.core_resume_error;
}
#include "actual.inc"

static void init(struct dwc3_qcom *qcom)
{
    memset(qcom, 0, sizeof(*qcom));
    memset(&observed, 0, sizeof(observed));
    qcom->dev = qcom->dwc.dev = &qcom->device;
    qcom->device.data = &qcom->dwc;
    qcom->uke_typec = true;
    qcom->current_role = USB_ROLE_HOST;
    observed.clocks_on = observed.core_resumed = true;
    assert(!pthread_mutex_init(&qcom->role_lock.native, NULL));
}
static void finish(struct dwc3_qcom *qcom)
{
    assert(!lock_held(&qcom->role_lock));
    assert(!pthread_mutex_destroy(&qcom->role_lock.native));
}

int main(void)
{
    struct dwc3_qcom qcom;
    init(&qcom);
    assert(!dwc3_qcom_pm_suspend(qcom.dev) && qcom.pm_suspended);
    dwc3_qcom_set_role_notifier(&qcom.dwc, USB_ROLE_NONE);
#if EXPECT_BASELINE
    assert(observed.unsafe_writes == 1 && observed.gets == 1);
    assert(!dwc3_qcom_pm_resume(qcom.dev));
    finish(&qcom);
    puts("Retained baseline reproduces system-suspended QSCRATCH access");
#else
    assert(!observed.writes && !observed.gets);
    assert(qcom.vbus_override_pending && !qcom.vbus_override);
    observed.restore_gadget = true;
    assert(!dwc3_qcom_pm_resume(qcom.dev));
    assert(!qcom.pm_suspended && !qcom.vbus_override_pending);
    assert(observed.writes == 2 && observed.writes_after_core == 1);
    assert(!observed.enabled && !observed.unsafe_writes);
    assert(observed.protected_points == 4);
    finish(&qcom);

    init(&qcom);
    assert(!dwc3_qcom_pm_suspend(qcom.dev));
    dwc3_qcom_set_role_notifier(&qcom.dwc, USB_ROLE_DEVICE);
    dwc3_qcom_set_role_notifier(&qcom.dwc, USB_ROLE_NONE);
    dwc3_qcom_set_role_notifier(&qcom.dwc, USB_ROLE_HOST);
    dwc3_qcom_set_role_notifier(&qcom.dwc, USB_ROLE_HOST);
    assert(!observed.writes && !observed.gets);
    assert(qcom.current_role == USB_ROLE_HOST && !qcom.vbus_override);
    assert(!dwc3_qcom_pm_resume(qcom.dev));
    assert(observed.writes == 1 && !observed.enabled && !observed.unsafe_writes);
    finish(&qcom);

    /* Independent truth tables preserve both full-profile and legacy behavior. */
    static const bool full_enabled[] = {false, false, true};
    static const bool legacy_enabled[] = {true, true, false};
    for (unsigned full = 0; full < 2; full++)
        for (unsigned before = 0; before < 3; before++)
            for (unsigned after = 0; after < 3; after++) {
                init(&qcom);
                qcom.uke_typec = full;
                qcom.current_role = before;
                dwc3_qcom_set_role_notifier(&qcom.dwc, after);
                assert(qcom.current_role == after && !observed.unsafe_writes);
                assert(observed.gets == (before != after));
                assert(observed.gets == observed.puts);
                assert(observed.writes == (before != after));
                if (before != after)
                    assert(observed.enabled == (full ? full_enabled[after] : legacy_enabled[before]));
                finish(&qcom);
            }

    init(&qcom);
    observed.runtime_error = -EIO;
    dwc3_qcom_set_role_notifier(&qcom.dwc, USB_ROLE_DEVICE);
    assert(qcom.current_role == USB_ROLE_HOST && !observed.writes && !observed.puts);
    finish(&qcom);

    init(&qcom);
    observed.core_suspend_error = -EBUSY;
    assert(dwc3_qcom_pm_suspend(qcom.dev) == -EBUSY && !qcom.pm_suspended);
    assert(observed.protected_points == 1 && observed.clocks_on);
    finish(&qcom);

    init(&qcom);
    observed.glue_suspend_error = -EIO;
    assert(dwc3_qcom_pm_suspend(qcom.dev) == -EIO && !qcom.pm_suspended);
    assert(observed.protected_points == 2);
    finish(&qcom);

    init(&qcom);
    assert(!dwc3_qcom_pm_suspend(qcom.dev));
    dwc3_qcom_set_role_notifier(&qcom.dwc, USB_ROLE_DEVICE);
    observed.glue_resume_error = -ENXIO;
    assert(dwc3_qcom_pm_resume(qcom.dev) == -ENXIO);
    assert(qcom.pm_suspended && qcom.vbus_override_pending && !observed.writes);
    observed.glue_resume_error = 0;
    observed.core_resume_error = -EIO;
    assert(dwc3_qcom_pm_resume(qcom.dev) == -EIO);
    assert(!qcom.vbus_override_pending && observed.enabled && !observed.unsafe_writes);
    finish(&qcom);
    puts("Actual role/sleep functions preserve deferred MMIO, lock coverage, role policy and errors");
#endif
    return 0;
}
