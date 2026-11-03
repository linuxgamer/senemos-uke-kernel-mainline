#!/usr/bin/env bash
# Execute the actual PAS stop transaction with host-only power/DMA ledgers.
set -Eeuo pipefail
source_file=${1:?Pass prepared qcom_q6v5_pas.c}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cerrno>
#include <cstdint>
#include <cstddef>
#include <cstdio>
#include <initializer_list>
#define fallthrough [[fallthrough]]
#define RPROC_CRASHED 3
using phys_addr_t=uint64_t;
CPP
if grep -q '^enum qcom_pas_stop_phase' "$source_file"; then
    awk '/^enum qcom_pas_stop_phase/ {emit=1} emit {print} emit && /^};/ {emit=0}' "$source_file" >> "$work/check.cpp"
    printf '#define HAVE_BOOT_GATE 1\n' >> "$work/check.cpp"
else
    cat >> "$work/check.cpp" <<'CPP'
enum qcom_pas_stop_phase { QCOM_PAS_STOP_IDLE,QCOM_PAS_STOP_PRIMARY,QCOM_PAS_STOP_DTB,QCOM_PAS_STOP_RESOURCES,QCOM_PAS_STOP_PROXY,QCOM_PAS_STOP_SMEM,QCOM_PAS_STOP_DONE };
#define HAVE_BOOT_GATE 0
CPP
fi
cat >> "$work/check.cpp" <<'CPP'
struct device {};
struct qcom_q6v5 {};
struct qcom_pas;
struct rproc { qcom_pas *priv; int state=2; };
struct qcom_pas {
    explicit qcom_pas(device *d):dev(d) {}
    device *dev; qcom_q6v5 q6v5; void *sysmon=nullptr;
    int pas_id=18,dtb_pas_id=37; bool decrypt_shutdown=false;
    unsigned int smem_host_id=5,proxy_regulator_level=384,proxy_regulator_count=3;
    phys_addr_t mem_phys=0x99900000,dtb_mem_phys=0x9ad00000;
    size_t mem_size=0x1400000,dtb_mem_size=0x80000;
    int proxy_error=0; qcom_pas_stop_phase stop_phase=QCOM_PAS_STOP_IDLE;
};
static qcom_pas *active;
static unsigned int shutdown_notices;
static void qcom_sysmon_prepare_shutdown(void *,bool) { shutdown_notices++; }
static int primary_error,dtb_error,request_error,proxy_error,smem_error,decrypt_error;
static unsigned int requests,primaries,dtbs,unmaps,unprepares,handovers,releases,smems,polls;
static bool primary_off,dtb_off,primary_map,dtb_map,clocks_live,rails_live,handover_needed;
template<class... T> void dev_err(device *,const char *,T...) {}
static int qcom_q6v5_request_stop(qcom_q6v5 *,void *) { requests++; return request_error; }
static int qcom_pas_shutdown(int id) {
    if(id==18) { primaries++; if(!primary_error) primary_off=true; return primary_error; }
    assert(id==37); dtbs++; if(!dtb_error) dtb_off=true; return dtb_error;
}
static int qcom_pas_shutdown_poll_decrypt(qcom_pas *) { polls++; if(!decrypt_error) primary_off=true; return decrypt_error; }
static void qcom_pas_unmap_carveout(rproc *,phys_addr_t base,size_t size) {
    unmaps++;
    if(base==active->mem_phys) { assert(primary_map && size==active->mem_size); primary_map=false; }
    else { assert(base==active->dtb_mem_phys && dtb_map && size==active->dtb_mem_size); dtb_map=false; }
}
static int qcom_q6v5_unprepare(qcom_q6v5 *) { assert(!unprepares); unprepares++; return handover_needed; }
static int qcom_pas_proxy_disable(qcom_pas *p) {
    releases++; p->proxy_error=proxy_error; if(!proxy_error) rails_live=false; return proxy_error;
}
static void qcom_pas_handover(qcom_q6v5 *) { handovers++; clocks_live=false; qcom_pas_proxy_disable(active); }
static int qcom_smem_bust_hwspin_lock_by_host(unsigned int host) { assert(host==5); smems++; return smem_error; }
CPP
awk '/^static bool qcom_pas_boot_allowed\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$source_file" >> "$work/check.cpp"
awk '/^static int qcom_pas_(halt|prepare_stop|stop)\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$source_file" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
static void reset(qcom_pas &p) {
    p=qcom_pas{p.dev}; active=&p;
    primary_error=dtb_error=request_error=proxy_error=smem_error=decrypt_error=0; shutdown_notices=0;
    requests=primaries=dtbs=unmaps=unprepares=handovers=releases=smems=polls=0;
    primary_off=dtb_off=false; primary_map=dtb_map=clocks_live=rails_live=handover_needed=true;
}
static void retained() { assert(primary_map && dtb_map && clocks_live && rails_live && !unmaps && !unprepares && !handovers && !smems); }
static void done(qcom_pas &p) { assert(primary_off && dtb_off && !primary_map && !dtb_map && !clocks_live && !rails_live && unmaps==2 && unprepares==1 && p.stop_phase==QCOM_PAS_STOP_DONE); }
int main() {
    device dev; qcom_pas p{&dev}; rproc r{&p};
    reset(p); primary_error=-EACCES;
    assert(qcom_pas_stop(&r)==-EACCES); retained();
    assert(requests==1 && primaries==1 && !dtbs && p.stop_phase==QCOM_PAS_STOP_PRIMARY);
    assert(qcom_pas_stop(&r)==-EACCES); retained(); assert(requests==1 && primaries==2);
    primary_error=0; assert(qcom_pas_stop(&r)==0); done(p);
    const auto prior_releases=releases; assert(qcom_pas_stop(&r)==0); assert(releases==prior_releases && primaries==3 && dtbs==1 && smems==1);
    reset(p); dtb_error=-EBUSY;
    assert(qcom_pas_stop(&r)==-EBUSY); retained(); assert(primary_off && !dtb_off && primaries==1 && dtbs==1);
    dtb_error=0; assert(qcom_pas_stop(&r)==0); done(p); assert(primaries==1 && dtbs==2 && requests==1);
    reset(p); proxy_error=-EIO;
    assert(qcom_pas_stop(&r)==-EIO); assert(primary_off && dtb_off && !primary_map && !dtb_map && !clocks_live && rails_live && unprepares==1 && releases==1 && !smems);
    proxy_error=0; assert(qcom_pas_stop(&r)==0); done(p); assert(unprepares==1 && handovers==1 && primaries==1 && dtbs==1);
    reset(p); smem_error=-EAGAIN;
    assert(qcom_pas_stop(&r)==-EAGAIN); assert(!primary_map && !clocks_live && !rails_live && p.stop_phase==QCOM_PAS_STOP_SMEM);
    smem_error=0; assert(qcom_pas_stop(&r)==0); done(p); assert(smems==2 && primaries==1 && dtbs==1 && handovers==1);
    reset(p); request_error=-ETIMEDOUT; assert(qcom_pas_stop(&r)==0); done(p);
    reset(p); p.decrypt_shutdown=true; primary_error=-EINVAL; decrypt_error=-ETIMEDOUT;
    assert(qcom_pas_stop(&r)==-ETIMEDOUT); retained(); assert(polls==1 && !dtbs);
    decrypt_error=0; assert(qcom_pas_stop(&r)==0); done(p); assert(polls==2);
    reset(p); p.dtb_pas_id=0; dtb_map=false; dtb_off=true; p.smem_host_id=0; p.proxy_regulator_level=0;
    assert(qcom_pas_stop(&r)==0 && primary_off && !primary_map && !clocks_live && !rails_live && unmaps==1 && !dtbs && !smems && releases==1);
    reset(p); handover_needed=false; clocks_live=rails_live=false;
    assert(qcom_pas_stop(&r)==0); done(p); assert(!handovers);
    reset(p); handover_needed=false; clocks_live=false; p.proxy_error=-EIO;
    assert(qcom_pas_stop(&r)==-EIO && p.stop_phase==QCOM_PAS_STOP_PROXY && !releases);
    assert(qcom_pas_stop(&r)==0); done(p); assert(!handovers);
#if HAVE_BOOT_GATE
    reset(p); primary_error=-EACCES;
    assert(qcom_pas_prepare_stop(&r)==-EACCES); retained(); assert(!dtbs);
    primary_error=0; assert(qcom_pas_prepare_stop(&r)==0);
    assert(primary_off && dtb_off && primary_map && dtb_map && clocks_live && rails_live && !unmaps);
    assert(qcom_pas_stop(&r)==0); done(p); assert(primaries==2 && dtbs==1 && shutdown_notices==1);
    reset(p); p.proxy_regulator_count=2;
    assert(qcom_pas_prepare_stop(&r)==0 && !requests && !primaries && !unmaps);
#endif
    reset(p); p.stop_phase=static_cast<qcom_pas_stop_phase>(7);
    assert(qcom_pas_stop(&r)==-EINVAL && !requests && !primaries && !unmaps);
#if HAVE_BOOT_GATE
    for(auto phase:{QCOM_PAS_STOP_IDLE,QCOM_PAS_STOP_PRIMARY,QCOM_PAS_STOP_DTB,QCOM_PAS_STOP_RESOURCES,QCOM_PAS_STOP_PROXY,QCOM_PAS_STOP_SMEM,QCOM_PAS_STOP_DONE}) {
        p.stop_phase=phase;
        assert(qcom_pas_boot_allowed(&p)==(phase==QCOM_PAS_STOP_IDLE || phase==QCOM_PAS_STOP_DONE));
    }
#endif
    puts("Actual PAS stop: shutdown/DTB failures retain maps and power; partial-stop/proxy/SMEM retries avoid repeated teardown; boot gate and legacy cases passed; host only");
}
CPP
"${CXX:-g++}" -std=c++20 -O1 -g -Wall -Wextra -Werror \
    -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
    "$work/check.cpp" -o "$work/check"
"$work/check"
if grep -q '^static bool qcom_pas_boot_allowed' "$source_file"; then
    for name in load start attach; do
        awk -v name="$name" '$0 ~ "^static int qcom_pas_"name"\\(" {emit=1} emit {print} emit && /^}/ {exit}' "$source_file" > "$work/$name"
        grep -Fq 'if (!qcom_pas_boot_allowed(pas))' "$work/$name"
    done
fi
