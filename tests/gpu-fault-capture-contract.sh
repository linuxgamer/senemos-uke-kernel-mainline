#!/usr/bin/env bash
# Actual fault-capture function with host mutexes; no GPU or SMMU emulation.
set -Eeuo pipefail
source_file=${1:?Pass prepared drivers/gpu/drm/msm/msm_gpu.c}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <future>
#include <mutex>
#include <thread>

struct mutex { std::mutex value; };
static void mutex_lock(struct mutex *m) { m->value.lock(); }
static bool mutex_trylock(struct mutex *m) { return m->value.try_lock(); }
static void mutex_unlock(struct mutex *m) { m->value.unlock(); }
struct device {};
struct platform_device { struct device dev; };
struct msm_gpu;
struct msm_memptrs { unsigned fence = 7; };
struct msm_ringbuffer { struct msm_memptrs *memptrs; };
struct msm_gpu_funcs { struct msm_ringbuffer *(*active_ring)(struct msm_gpu *); };
struct msm_gpu {
    struct mutex lock;
    struct msm_gpu_funcs *funcs;
    struct platform_device *pdev;
};
struct msm_gem_submit { bool fault_dumped; };
struct msm_gpu_fault_info {};
static struct msm_memptrs memptrs;
static struct msm_ringbuffer ring{&memptrs};
static struct msm_gem_submit *pending;
static unsigned captures, pm_gets, pm_puts, saved, restored;
static struct msm_ringbuffer *active_ring(struct msm_gpu *) { return &ring; }
static struct msm_gem_submit *find_submit(struct msm_ringbuffer *r, unsigned fence) {
    assert(r == &ring && fence == memptrs.fence + 1);
    return pending;
}
static unsigned memalloc_noreclaim_save() { ++saved; return 42; }
static void memalloc_noreclaim_restore(unsigned flags) { assert(flags == 42); ++restored; }
static void get_comm_cmdline(struct msm_gem_submit *submit, char **comm, char **cmd) {
    assert(submit == pending); *comm = nullptr; *cmd = nullptr;
}
static int pm_runtime_get_sync(struct device *) { ++pm_gets; return 0; }
static int pm_runtime_put_sync(struct device *) { ++pm_puts; return 0; }
static void msm_gpu_crashstate_capture(struct msm_gpu *, struct msm_gem_submit *submit,
                                     struct msm_gpu_fault_info *, char *, char *) {
    assert(submit == pending); ++captures;
}
static void kfree(void *ptr) { std::free(ptr); }
CPP
awk '/^void msm_gpu_fault_crashstate_capture\(/ {emit=1} emit {print} emit && /^}/ {exit}' "$source_file" >> "$work/check.cpp"
test "$(grep -c '^void msm_gpu_fault_crashstate_capture(' "$work/check.cpp")" = 1
cat >> "$work/check.cpp" <<'CPP'
static void reset() { captures = pm_gets = pm_puts = saved = restored = 0; pending = nullptr; }
static void unlocked(struct msm_gpu &gpu) {
    assert(gpu.lock.value.try_lock()); gpu.lock.value.unlock();
}
int main() {
    struct msm_gpu_funcs funcs{active_ring};
    struct platform_device pdev;
    struct msm_gpu gpu{{}, &funcs, &pdev};
    struct msm_gpu_fault_info info;

    reset();
    msm_gpu_fault_crashstate_capture(&gpu, &info);
    assert(captures == 1 && pm_gets == 1 && pm_puts == 1 && saved == 1 && restored == 1);
    unlocked(gpu);

    struct msm_gem_submit submit{true};
    reset(); pending = &submit;
    msm_gpu_fault_crashstate_capture(&gpu, &info);
    assert(!captures && !pm_gets && !pm_puts && !saved && !restored);
    unlocked(gpu);

    reset(); pending = &submit; submit.fault_dumped = false;
    msm_gpu_fault_crashstate_capture(&gpu, &info);
    assert(submit.fault_dumped && captures == 1 && pm_gets == 1 && pm_puts == 1);
    assert(saved == 1 && restored == 1);
    unlocked(gpu);

    reset();
    gpu.lock.value.lock();
    // Recovery holds this mutex until the fault handler completes the SMMU stall.
    std::promise<void> fault_done;
    auto completion = fault_done.get_future();
    std::thread fault([&] {
        msm_gpu_fault_crashstate_capture(&gpu, &info);
        fault_done.set_value();
    });
    if (completion.wait_for(std::chrono::seconds(2)) != std::future_status::ready) {
        std::fputs("Fault completion blocked behind recovery's GPU mutex\n", stderr);
        std::_Exit(1);
    }
    assert(!captures && !pm_gets && !pm_puts && !saved && !restored);
    gpu.lock.value.unlock();
    fault.join();

    msm_gpu_fault_crashstate_capture(&gpu, &info);
    assert(captures == 1 && pm_gets == 1 && pm_puts == 1 && saved == restored);
    unlocked(gpu);
    std::puts("Actual fault capture: uncontended dump, duplicate skip, cleanup and recovery/fault lock cycle passed");
}
CPP
"${CXX:-g++}" -std=c++20 -O2 -Wall -Wextra -Werror -Wno-unused-function -pthread "$work/check.cpp" -o "$work/check"
"$work/check"
