#!/usr/bin/env bash
# Actual Sysmon preparation/stop functions; QMI/SMD and notifications are mocked.
set -Eeuo pipefail
source_file=${1:?Pass prepared qcom_sysmon.c}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cstdio>
#include <cstddef>
#define HZ 1000
#define SSCTL_SSR_EVENT_BEFORE_POWERUP 0
#define SSCTL_SSR_EVENT_BEFORE_SHUTDOWN 2
#define container_of(ptr,type,member) static_cast<type *>((ptr)->owner)
struct device {};
struct mutex { bool locked=false; };
struct completion {};
struct rproc_subdev { void *owner; };
struct qcom_sysmon {
    rproc_subdev subdev{this}; const char *name="cdsp"; int state=0;
    mutex state_lock; completion ssctl_comp; device *dev=nullptr;
    int ssctl_instance=1,ssctl_version=2; void *ept=nullptr;
    bool shutdown_acked=false,shutdown_requested=false;
};
struct sysmon_event { const char *subsys_name; int ssr_event; };
static int sysmon_notifiers;
static unsigned int qmi_requests,smd_requests,waits,notices,errors;
static bool reply=true,service_ready=true;
static int ssctl_request_shutdown(qcom_sysmon *) { qmi_requests++; return reply; }
static int sysmon_request_shutdown(qcom_sysmon *) { smd_requests++; return reply; }
static unsigned long wait_for_completion_timeout(completion *,unsigned long timeout) { assert(timeout==HZ/2); waits++; return service_ready; }
static void mutex_lock(mutex *m) { assert(!m->locked); m->locked=true; }
static void mutex_unlock(mutex *m) { assert(m->locked); m->locked=false; }
static int blocking_notifier_call_chain(int *,int,void *data) { auto *event=static_cast<sysmon_event *>(data); assert(event->subsys_name); notices++; return 0; }
template<class... T> void dev_err(device *,const char *,T...) { errors++; }
CPP
awk '/^(static int sysmon_prepare|void qcom_sysmon_prepare_shutdown|static void sysmon_stop)\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$source_file" >> "$work/check.cpp"
if ! grep -q '^void qcom_sysmon_prepare_shutdown' "$source_file"; then
    cat >> "$work/check.cpp" <<'CPP'
void qcom_sysmon_prepare_shutdown(qcom_sysmon *s,bool crashed) { if(s) sysmon_stop(&s->subdev,crashed); }
CPP
fi
cat >> "$work/check.cpp" <<'CPP'
static void reset() { qmi_requests=smd_requests=waits=notices=errors=0; reply=service_ready=true; }
int main() {
    qcom_sysmon s;
    reset(); qcom_sysmon_prepare_shutdown(&s,false);
    assert(qmi_requests==1 && waits==1 && notices==1 && s.shutdown_acked);
    reply=false; sysmon_stop(&s.subdev,false);
    assert(qmi_requests==1 && notices==1 && s.shutdown_acked);
    qcom_sysmon_prepare_shutdown(&s,false); assert(qmi_requests==1 && notices==1);
    assert(sysmon_prepare(&s.subdev)==0 && !s.shutdown_acked && !s.shutdown_requested);
    sysmon_stop(&s.subdev,false); assert(qmi_requests==2 && !s.shutdown_acked && s.shutdown_requested);
    sysmon_stop(&s.subdev,false); assert(qmi_requests==2);
    reset(); assert(sysmon_prepare(&s.subdev)==0); notices=0;
    qcom_sysmon_prepare_shutdown(&s,true); sysmon_stop(&s.subdev,true);
    assert(!qmi_requests && !smd_requests && !waits && notices==1 && !s.shutdown_acked);
    reset(); assert(sysmon_prepare(&s.subdev)==0); notices=0;
    s.ssctl_version=0; s.ssctl_instance=0; s.ept=&s;
    qcom_sysmon_prepare_shutdown(&s,false); sysmon_stop(&s.subdev,false);
    assert(smd_requests==1 && !qmi_requests && !waits && notices==1 && s.shutdown_acked);
    reset(); assert(sysmon_prepare(&s.subdev)==0); notices=0;
    s.ssctl_version=0; s.ept=nullptr;
    qcom_sysmon_prepare_shutdown(&s,false); sysmon_stop(&s.subdev,false);
    assert(!qmi_requests && !smd_requests && !s.shutdown_acked && notices==1);
    reset(); assert(sysmon_prepare(&s.subdev)==0); notices=0;
    s.ssctl_version=2; s.ssctl_instance=1; service_ready=false; reply=false;
    qcom_sysmon_prepare_shutdown(&s,false); sysmon_stop(&s.subdev,false);
    assert(errors==1 && waits==1 && qmi_requests==1 && !s.shutdown_acked && notices==1);
    qcom_sysmon_prepare_shutdown(nullptr,false); assert(notices==1 && qmi_requests==1);
    puts("Actual Sysmon: one shutdown request/notification per boot, real ACK retention, restart reset, crash, QMI/SMD/missing-service cases passed; host only");
}
CPP
"${CXX:-g++}" -std=c++20 -O1 -g -Wall -Wextra -Werror \
    -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
    "$work/check.cpp" -o "$work/check"
"$work/check"
