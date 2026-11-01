#!/usr/bin/env bash
# Exercise the actual cpufreq core function without sysfs or hardware access.
set -Eeuo pipefail
source=${1:?Pass drivers/cpufreq/cpufreq.c}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <errno.h>
struct cpufreq_policy { bool boost_supported; bool boost_enabled; int error; };
static struct { bool boost_enabled; } driver, *cpufreq_driver = &driver;
static struct cpufreq_policy policies[3];
static unsigned count, calls;
#define write_lock_irqsave(lock, flags) ((flags) = 0)
#define write_unlock_irqrestore(lock, flags) ((void)(flags))
#define cpus_read_lock() ((void)0)
#define cpus_read_unlock() ((void)0)
#define for_each_active_policy(p) for (p = policies; p < policies + count; ++p)
#define likely(x) (x)
#define unlikely(x) (x)
#define pr_err(...) ((void)0)
static int policy_set_boost(struct cpufreq_policy *p, bool enable)
{
    calls++;
    if (p->error) return p->error;
    p->boost_enabled = enable;
    return 0;
}
C
awk '/^static int cpufreq_boost_trigger_state\(int state\)$/ {emit=1}
 emit {print} emit && /^}/ {found=1;exit} END {if(!found)exit 1}' "$source" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
int main(void)
{
    for (unsigned initial=0;initial<=1;initial++)
        for (unsigned request=0;request<=1;request++)
            for (unsigned mask=0;mask<8;mask++)
                for (unsigned failure=0;failure<4;failure++) {
                    driver.boost_enabled=initial;
                    count=3;calls=0;
                    for (unsigned i=0;i<3;i++)
                        policies[i]=(struct cpufreq_policy){
                            .boost_supported=!!(mask & (1U<<i)),
                            .boost_enabled=initial,
                            .error=failure==i+1?-EIO:0};
                    int ret=cpufreq_boost_trigger_state(request);
                    bool rejects=mask==0 ||
                        (failure && (mask & (1U<<(failure-1))));
                    assert((ret!=0)==rejects);
                    assert(driver.boost_enabled==(rejects?initial:request));
                    for(unsigned i=0;i<3;i++)
                        if(!policies[i].boost_supported)
                            assert(policies[i].boost_enabled==initial);
                    if(!mask)assert(calls==0);
                }
    for(unsigned initial=0;initial<=1;initial++) {
        driver.boost_enabled=initial;count=0;
        assert(cpufreq_boost_trigger_state(initial)==-EOPNOTSUPP);
        assert(driver.boost_enabled==initial);
    }
    return 0;
}
C
"${CC:-cc}" -std=gnu11 -O1 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check"
echo 'PASS: actual boost error rollback, repeated state, absent/unsupported/mixed policies; host only'
