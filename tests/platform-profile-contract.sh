#!/usr/bin/env bash
# Exercise the actual kernel preference transaction with host-only QoS providers.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/test.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
typedef int32_t s32;
#define UKE_POLICIES 3
#define UKE_GPU_MAX_KHZ 950000
#define UKE_GPU_SAVER_KHZ 500000
#define FREQ_QOS_MIN_DEFAULT_VALUE 0
#define FREQ_QOS_MAX_DEFAULT_VALUE INT_MAX
#define DEV_PM_QOS_MIN_FREQUENCY 1
#define EPROBE_DEFER 517
#define PAGE_SIZE 4096
#define READ_ONCE(value) (value)
#define WRITE_ONCE(target, value) ((target)=(value))
#define scnprintf snprintf
#define KOBJ_CHANGE 1
#define module_param_cb(name, ops, arg, mode) _Static_assert(mode==0444,"Read-only handoff state")
#define dev_err(dev, text) ((void)(dev))
enum platform_profile_option { PLATFORM_PROFILE_LOW_POWER, PLATFORM_PROFILE_BALANCED,
 PLATFORM_PROFILE_PERFORMANCE, PLATFORM_PROFILE_CUSTOM, INVALID_PROFILE };
struct device { void *data; int kobj; };
struct kernel_param { int unused; };
struct kernel_param_ops { int (*get)(char *,const struct kernel_param *); int (*set)(const char *,const struct kernel_param *); };
struct cpufreq_governor { const char *name; };
struct cpufreq_policy { struct { unsigned min_freq, max_freq; } cpuinfo;
 struct cpufreq_governor *governor; int rwsem; };
struct freq_qos_request { int requested; };
struct dev_pm_qos_request { int requested; };
static unsigned step, fail_a, fail_b;
static int gpu_min;
static unsigned events;
static int kobject_uevent(int *obj, int action) { (void)obj; assert(action==KOBJ_CHANGE); events++; return 0; }
static bool board=true, soc=true;
static unsigned cores=8;
static const char *cpu_driver="qcom-cpufreq-hw";
static bool of_machine_is_compatible(const char *name) {
 if(!strcmp(name,"xiaomi,uke"))return board;
 assert(!strcmp(name,"qcom,sm7675")); return soc;
}
static unsigned num_possible_cpus(void) { return cores; }
static const char *cpufreq_get_current_driver(void) { return cpu_driver; }
static void down_read(int *lock) { (void)lock; }
static void up_read(int *lock) { (void)lock; }
static void *dev_get_drvdata(struct device *dev) { return dev->data; }
static void __set_bit(unsigned bit, unsigned long *bits) { *bits |= 1UL << bit; }
static int request_status(void) { step++; return step==fail_a || step==fail_b ? -EIO : 1; }
static int freq_qos_update_request(struct freq_qos_request *req, int value) {
 int result=request_status(); if(result>=0)req->requested=value; return result;
}
static int dev_pm_qos_update_request(struct dev_pm_qos_request *req, int value) {
 int result=request_status(); if(result>=0)req->requested=value; return result;
}
static int dev_pm_qos_read_value(struct device *dev, int kind) {
 (void)dev; assert(kind==DEV_PM_QOS_MIN_FREQUENCY); return gpu_min;
}
C
awk '/^\/\* Handoff ABI v1:/ {copy=1} /^static const struct platform_profile_ops / {exit} copy' \
    "$root/src/power/uke-platform-profile.c" >> "$work/test.c"
cat >> "$work/test.c" <<'C'
static struct cpufreq_governor schedutil={"schedutil"}, other={"powersave"};
static struct cpufreq_policy policies[UKE_POLICIES];
static struct device device;
static struct uke_profile profile;
static void reset(void) {
 memset(&profile,0,sizeof(profile)); step=fail_a=fail_b=0; gpu_min=0;
 device.data=&profile; profile.dev=profile.gpu=&device; profile.consistent=true;
 profile.count=UKE_POLICIES; profile.selected=PLATFORM_PROFILE_BALANCED;
 profile.gpu_value=profile.gpu_request.requested=UKE_GPU_MAX_KHZ;
 for(unsigned i=0;i<UKE_POLICIES;i++) {
  policies[i].cpuinfo.min_freq=100+i; policies[i].cpuinfo.max_freq=1000+i;
  policies[i].governor=&schedutil; profile.cpu[i].policy=&policies[i];
  profile.cpu[i].max_value=profile.cpu[i].max_request.requested=INT_MAX;
 }
}
static void balanced(void) {
 assert(profile.consistent && profile.selected==PLATFORM_PROFILE_BALANCED);
 assert(profile.gpu_value==UKE_GPU_MAX_KHZ && profile.gpu_request.requested==UKE_GPU_MAX_KHZ);
 for(unsigned i=0;i<UKE_POLICIES;i++) {
  assert(profile.cpu[i].min_value==0 && profile.cpu[i].min_request.requested==0);
  assert(profile.cpu[i].max_value==INT_MAX && profile.cpu[i].max_request.requested==INT_MAX);
 }
}
int main(void) {
 char state[PAGE_SIZE];
 assert(!uke_profile_status_ops.set);
 uke_profile_publish_state(&device,-EPROBE_DEFER);
 assert(!probe_status && !events);
 uke_profile_publish_state(&device,0); assert(probe_status==1 && events==1);
 assert(uke_profile_status_ops.get(state,NULL)==1 && !strcmp(state,"1"));
 uke_profile_publish_state(&device,0); assert(events==1);
 uke_profile_publish_state(&device,-EIO); assert(probe_status==-1 && events==2);
 uke_profile_publish_state(&device,-EINVAL); assert(events==2);
 uke_profile_publish_state(&device,-EPROBE_DEFER); assert(!probe_status && events==3);
 uke_profile_publish_state(NULL,-ENOMEM); assert(probe_status==-1 && events==3);
 assert(!uke_profile_admit());
 board=false; assert(uke_profile_admit()==-ENODEV); board=true;
 soc=false; assert(uke_profile_admit()==-ENODEV); soc=true;
 cores=4; assert(uke_profile_admit()==-ENODEV); cores=8;
 cpu_driver=NULL; assert(uke_profile_admit()==-EPROBE_DEFER);
 cpu_driver="foreign"; assert(uke_profile_admit()==-ENODEV);
 cpu_driver="qcom-cpufreq-hw";
 unsigned long choices=0;
 assert(!uke_profile_choices(NULL,&choices));
 assert(choices==((1UL<<PLATFORM_PROFILE_LOW_POWER)|(1UL<<PLATFORM_PROFILE_BALANCED)|
                 (1UL<<PLATFORM_PROFILE_PERFORMANCE)));
 reset();
 assert(uke_profile_set(&device,INVALID_PROFILE)==-EOPNOTSUPP && !step);
 gpu_min=UKE_GPU_SAVER_KHZ+1;
 assert(uke_profile_set(&device,PLATFORM_PROFILE_LOW_POWER)==-EBUSY && !step);
 gpu_min=0; policies[1].governor=&other;
 assert(uke_profile_set(&device,PLATFORM_PROFILE_PERFORMANCE)==-EBUSY && !step);
 enum platform_profile_option selected;
 assert(!uke_profile_get(&device,&selected) && selected==PLATFORM_PROFILE_CUSTOM);
 reset();
 assert(!uke_profile_set(&device,PLATFORM_PROFILE_LOW_POWER));
 assert(profile.gpu_value==UKE_GPU_SAVER_KHZ);
 for(unsigned i=0;i<UKE_POLICIES;i++)assert(profile.cpu[i].max_value==(int)policies[i].cpuinfo.min_freq);
 assert(!uke_profile_set(&device,PLATFORM_PROFILE_PERFORMANCE));
 for(unsigned i=0;i<UKE_POLICIES;i++)assert(profile.cpu[i].min_value==(int)policies[i].cpuinfo.max_freq);
 assert(!uke_profile_get(&device,&selected) && selected==PLATFORM_PROFILE_PERFORMANCE);
 assert(!uke_profile_set(&device,PLATFORM_PROFILE_BALANCED)); balanced();
 for(unsigned failure=1;failure<=10;failure++) {
  reset(); fail_a=failure;
  assert(uke_profile_set(&device,PLATFORM_PROFILE_PERFORMANCE)==-EIO); balanced();
 }
 reset(); assert(!uke_profile_set(&device,PLATFORM_PROFILE_PERFORMANCE));
 step=0; fail_a=4; fail_b=5;
 assert(uke_profile_set(&device,PLATFORM_PROFILE_LOW_POWER)==-EIO && !profile.consistent);
 assert(!uke_profile_get(&device,&selected) && selected==PLATFORM_PROFILE_CUSTOM);
 assert(profile.cpu[0].max_value==(int)policies[0].cpuinfo.min_freq);
 fail_a=fail_b=0;
 assert(!uke_profile_set(&device,PLATFORM_PROFILE_BALANCED)); balanced();
 /* The saved preference is independent of an aggregate thermal ceiling. */
 reset(); const int thermal_ceiling=350000; fail_a=3;
 assert(uke_profile_set(&device,PLATFORM_PROFILE_LOW_POWER)==-EIO); balanced();
 assert((profile.gpu_request.requested<thermal_ceiling ? profile.gpu_request.requested : thermal_ceiling)==thermal_ceiling);
 return 0;
}
C
${CC:-cc} -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
    "$work/test.c" -o "$work/test"
"$work/test"
printf '%s\n' 'Actual Uke QoS preference transaction: profiles, hardware-derived CPU bounds, foreign governor/minimum refusal, ten failure points, partial rollback and recovery passed; host only.'
grep -Fxq 'MODULE_VERSION("1");' "$root/src/power/uke-platform-profile.c"
