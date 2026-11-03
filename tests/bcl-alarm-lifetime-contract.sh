#!/usr/bin/env bash
# Execute the actual alarm callbacks with deterministic teardown interleavings.
set -Eeuo pipefail
source=${1:?Pass prepared qcom-bcl-hwmon.c}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
ulimit -c 0
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cerrno>
#include <cstddef>
#include <cstdio>
#include <vector>
#define ARRAY_SIZE(a) int(sizeof(a)/sizeof((a)[0]))
#define READ_ONCE(x) (x)
#define WRITE_ONCE(x,y) ((x)=(y))
#define container_of(p,t,m) reinterpret_cast<t *>(reinterpret_cast<char *>(p)-offsetof(t,m))
#define scoped_guard(t,p) for(bool once=true;once;once=false)
#define JOIN_(a,b) a##b
#define JOIN(a,b) JOIN_(a,b)
struct guard_dummy { explicit guard_dummy(void *) {} };
#define guard(t) guard_dummy JOIN(g,__LINE__)
#define INIT_DELAYED_WORK(w,f) ((w)->fn=(f))
#define IRQF_ONESHOT 1
#define IRQF_TRIGGER_RISING 2
#define IRQ_HANDLED 1
#define BCL_ALARM_POLLING_MS 50
using irqreturn_t=int;
struct mutex {};
struct work_struct {};
struct delayed_work { work_struct work; void (*fn)(work_struct *)=nullptr; bool queued=false; };
struct device {};
struct platform_device { device dev; };
struct bcl_device;
struct bcl_alarm_data {
    mutex a_lock; delayed_work alarm_poll_work;
    bcl_device *device=nullptr; int type=0,irq=0;
    bool irq_enabled=false,irq_wake_enabled=false,shutting_down=false;
};
struct bcl_device { device *dev; mutex lock; bcl_alarm_data bcl_alarms[3]; bool legacy_uke=false; };
static const char * const bcl_int_names[]={"max-min","critical","emergency"};
static const char * const bcl_uke_int_names[]={"bcl-lvl0","bcl-lvl1","bcl-lvl2"};
static int status_value,read_error,fail_at,steps,notifications;
static bool wake[3],requested[3],enabled[3],deliver_on_request,resume_poll_on_cancel;
static bool resume_between_cleanups;
struct resource { void (*cleanup)(void *); void *data; int irq; };
static std::vector<resource> resources;
static bool fail() { return ++steps==fail_at; }
static int bcl_read_alarm_status(bcl_device *,int,long *v) { if(read_error)return read_error;*v=status_value;return 0; }
static void bcl_hwmon_notify_event(bcl_device *,int) { notifications++; }
static unsigned msecs_to_jiffies(unsigned v) { return v; }
static void schedule_delayed_work(delayed_work *w,unsigned delay) { assert(delay==50);w->queued=true; }
static void cancel_delayed_work_sync(delayed_work *w) {
    if(resume_poll_on_cancel) { resume_poll_on_cancel=false;w->fn(&w->work); }
    w->queued=false;
}
static int enable_irq_wake(int irq) { assert(irq>=0&&irq<3&&requested[irq]&&!wake[irq]);wake[irq]=true;return 0; }
static void disable_irq_wake(int irq) { assert(requested[irq]&&wake[irq]);wake[irq]=false; }
static void enable_irq(int irq) { assert(requested[irq]&&!enabled[irq]);enabled[irq]=true; }
static void disable_irq_nosync(int irq) { assert(requested[irq]&&enabled[irq]);enabled[irq]=false; }
static int devm_mutex_init(device *,mutex *) { return fail()?-ENOMEM:0; }
static int platform_get_irq_byname(platform_device *,const char *name) {
    if(fail())return -EPROBE_DEFER;
    for(int i=0;i<3;i++)if(name==bcl_int_names[i]||name==bcl_uke_int_names[i])return i;
    assert(false);return -EINVAL;
}
static int devm_request_threaded_irq(device *,int irq,void *,irqreturn_t (*fn)(int,void *),int flags,const char *,void *arg) {
    assert(flags==(IRQF_ONESHOT|(static_cast<bcl_alarm_data *>(arg)->device->legacy_uke?IRQF_TRIGGER_RISING:0)));
    if(fail())return -EBUSY;
    assert(!requested[irq]);requested[irq]=enabled[irq]=true;
    resources.push_back({nullptr,nullptr,irq});
    if(deliver_on_request)fn(irq,arg);
    return 0;
}
static int devm_add_action_or_reset(device *,void (*fn)(void *),void *arg) {
    if(fail()) { fn(arg);return -ENOMEM; }
    resources.push_back({fn,arg,-1});return 0;
}
static void release() {
    while(!resources.empty()) {
        auto r=resources.back();resources.pop_back();
        if(r.cleanup) {
            r.cleanup(r.data);
            auto *a=static_cast<bcl_alarm_data *>(r.data);
            if(resume_between_cleanups&&a->irq==0) {
                resume_between_cleanups=false;a->alarm_poll_work.fn(&a->alarm_poll_work.work);
            }
        }
        else { assert(requested[r.irq]&&!wake[r.irq]);requested[r.irq]=enabled[r.irq]=false; }
    }
}
CPP
# Match the kernel's private errno without importing kernel headers on the host.
sed -i '/using irqreturn_t/i #define EPROBE_DEFER 517' "$work/check.cpp"
awk '/^static void bcl_alarm_enable_poll/{p=1} /^static umode_t bcl_hwmon_is_visible/{p=0} p{print}' "$source" >> "$work/check.cpp"
awk '/^static void bcl_alarm_work_cleanup_action/{p=1} /^static int bcl_regmap_field_init/{p=0} p{print}' "$source" >> "$work/check.cpp"
# C permits these implicit void-pointer conversions; the C++ harness needs casts.
sed -i 's/struct bcl_alarm_data \*alarm = data;/struct bcl_alarm_data *alarm = static_cast<struct bcl_alarm_data *>(data);/' "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
static void reset() {
    assert(resources.empty());steps=notifications=fail_at=read_error=0;status_value=1;
    deliver_on_request=resume_poll_on_cancel=resume_between_cleanups=false;
    for(int i=0;i<3;i++)assert(!wake[i]&&!requested[i]);
}
int main(int argc,char **) {
    platform_device p;reset();bcl_device b{.dev=&p.dev};
    assert(!bcl_alarm_irq_init(&p,&b));int total=steps;
    auto &a=b.bcl_alarms[0];
    assert(bcl_handle_alarm(0,&a)==IRQ_HANDLED&&!enabled[0]&&!wake[0]&&a.alarm_poll_work.queued);
    read_error=-EIO;a.alarm_poll_work.queued=false;bcl_alarm_enable_poll(&a.alarm_poll_work.work);
    assert(a.alarm_poll_work.queued&&!enabled[0]&&!wake[0]);
    read_error=0;status_value=0;bcl_alarm_enable_poll(&a.alarm_poll_work.work);
    assert(enabled[0]&&wake[0]&&notifications==2);
    release();for(auto &v:b.bcl_alarms)assert(v.shutting_down&&!v.alarm_poll_work.queued);
    for(int f=1;argc==1&&f<=total;f++) {
        reset();bcl_device trial{.dev=&p.dev};fail_at=f;deliver_on_request=true;
        assert(bcl_alarm_irq_init(&p,&trial)<0);release();
        for(auto &v:trial.bcl_alarms)assert(!v.alarm_poll_work.queued);
    }
    reset();bcl_device trial{.dev=&p.dev};deliver_on_request=argc==1;
    assert(!bcl_alarm_irq_init(&p,&trial));
    if(argc==1)for(int i=0;i<3;i++)assert(!enabled[i]&&!wake[i]);
    else bcl_handle_alarm(0,&trial.bcl_alarms[0]);
    // A previously running poll resumes during cleanup after the alarm clears.
    status_value=0;resume_poll_on_cancel=true;resume_between_cleanups=true;release();
    for(auto &v:trial.bcl_alarms)assert(v.shutting_down&&!v.alarm_poll_work.queued);
    reset();bcl_device legacy{.dev=&p.dev};legacy.legacy_uke=true;
    assert(!bcl_alarm_irq_init(&p,&legacy));release();
    puts("PASS: actual BCL IRQ/poll, read-error retry, teardown interleaving and every IRQ setup failure; host only");
}
CPP
"${CXX:-c++}" -std=gnu++20 -O1 -Wall -Wextra -Werror -Wno-unused-parameter \
    -Wno-missing-field-initializers -fsanitize=address,undefined \
    -fno-omit-frame-pointer "$work/check.cpp" -o "$work/check"
"$work/check" ${2:+"$2"}
