#!/usr/bin/env bash
# Actual source functions with host-only resource fault injection.
set -Eeuo pipefail
iris=${1:?Pass the prepared Iris directory}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <algorithm>
#include <cassert>
#include <cerrno>
#include <climits>
#include <cstring>
#include <string>
#include <vector>
using u32 = unsigned;
struct iris_core;
struct vpu_ops {
    int (*power_on_controller)(iris_core *);
    int (*power_on_hw)(iris_core *);
    void (*power_off_hw)(iris_core *);
    int (*power_off_controller)(iris_core *);
    int (*power_off)(iris_core *){};
};
struct icc_info { const char *name; unsigned long bw_min_kbps, bw_max_kbps; };
struct icc_bulk_data { const char *name; unsigned long avg_bw, peak_bw; };
struct iris_hfi_sys_ops { int (*sys_interframe_powercollapse)(iris_core *); };
struct platform_data { const struct vpu_ops *vpu_ops; const icc_info *icc_tbl; };
struct iris_core {
    void *dev;
    const platform_data *iris_platform_data;
    icc_bulk_data *icc_tbl;
    int icc_count;
    struct { unsigned long icc_bw, clk_freq; } power;
    int irq;
    unsigned intr_status;
    const iris_hfi_sys_ops *hfi_sys_ops;
    int state{};
};
enum { IRIS_CORE_ERROR = 2 };
static std::vector<std::string> events;
static int fault, bulk_calls, native_off_error;
static int record(const char *name, int stage) {
    events.emplace_back(name); return fault == stage ? -EREMOTEIO : 0;
}
static int icc_bulk_set_bw(int, icc_bulk_data *) { ++bulk_calls; return record("icc", 1); }
#define BW_THRESHOLD 50000
#define typeof(value) decltype(value)
#define clamp_t(type, value, low, high) std::clamp<type>(value, low, high)
#define abs(value) std::abs(static_cast<long>(value))
CPP
awk '/^int iris_set_icc_bw\(/ { emit=1 } emit { print } emit && /^}/ { exit }' \
    "$iris/iris_resources.c" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
static int controller_on(iris_core *) { return record("controller-on", 2); }
static int hardware_on(iris_core *) { return record("hardware-on", 3); }
static void hardware_off(iris_core *) { record("hardware-off", 0); }
static int controller_off(iris_core *) { return record("controller-off", 0); }
static int iris_unset_icc_bw(iris_core *) { return record("icc-off", 0); }
static int iris_opp_set_rate(void *, unsigned long) { return record("rate", 4); }
static void iris_vpu_set_preset_registers(iris_core *) { record("presets", 0); }
static void iris_vpu_interrupt_init(iris_core *) { record("interrupt-init", 0); }
static void enable_irq(int) { record("irq-on", 0); }
#define dev_err(...) ((void)0)
CPP
awk '/^int iris_vpu_power_on\(/ { emit=1 } emit { print } emit && /^}/ { exit }' \
    "$iris/iris_vpu_common.c" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
static int iris_set_hw_state(iris_core *, bool resume) { return record(resume ? "resume" : "suspend", resume ? 5 : 0); }
static int iris_vpu_boot_firmware(iris_core *) { return record("boot", 6); }
static int iris_vpu_switch_to_hwmode(iris_core *) { return record("hwmode", 7); }
static int powercollapse(iris_core *) { return record("pc", 8); }
static int iris_vpu_power_off(iris_core *) { return record("power-off", 9); }
static void iris_vpu_enable_irq(iris_core *) {}
static int native_off(iris_core *) { record("native-off", 10); return native_off_error; }
CPP
awk '/^int iris_hfi_pm_resume\(/ { emit=1 } emit { print } emit && /^}/ { exit }' \
    "$iris/iris_hfi_common.c" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
int main() {
    const vpu_ops ops{controller_on, hardware_on, hardware_off, controller_off};
    const icc_info limits[]{ {"video-mem", 1000, 15000000} };
    const platform_data platform{&ops, limits};
    const iris_hfi_sys_ops hfi{powercollapse};
    icc_bulk_data paths[]{ {"video-mem", 1000, 0} };
    iris_core core{nullptr, &platform, paths, 1, {1000, 0}, 0, 0, &hfi};
    fault = 1; bulk_calls = 0;
    assert(iris_set_icc_bw(&core, 500000) == -EREMOTEIO);
    assert(core.power.icc_bw == 0);
    fault = 0;
    assert(iris_set_icc_bw(&core, 500000) == 0 && bulk_calls == 2);
    assert(core.power.icc_bw == 500000);
    assert(iris_set_icc_bw(&core, 500100) == 0 && bulk_calls == 2);
    for (int stage = 1; stage <= 4; ++stage) {
        fault = stage; events.clear(); core.power.icc_bw = 0;
        assert(iris_vpu_power_on(&core) == -EREMOTEIO);
        assert(std::find(events.begin(), events.end(), "presets") == events.end());
        assert(std::find(events.begin(), events.end(), "irq-on") == events.end());
        if (stage == 4)
            assert((events == std::vector<std::string>{"icc", "controller-on", "hardware-on", "rate", "hardware-off", "controller-off", "icc-off"}));
    }
    for (int stage = 1; stage <= 8; ++stage) {
        fault = stage; events.clear(); core.power.icc_bw = 0;
        assert(iris_hfi_pm_resume(&core) == -EREMOTEIO);
        if (stage >= 6) assert(events[events.size()-2] == "suspend");
        if (stage >= 5) assert(events.back() == "power-off");
    }
    fault = 0; core.power.icc_bw = 0;
    assert(iris_hfi_pm_resume(&core) == 0);
    vpu_ops native=ops; native.power_off=native_off;
    const platform_data native_platform{&native, limits};
    core.iris_platform_data=&native_platform;
    for (int stage=2; stage<=4; ++stage) {
        fault=stage; events.clear(); core.power.icc_bw=0;
        assert(iris_vpu_power_on(&core)==-EREMOTEIO);
        assert(std::count(events.begin(),events.end(),"native-off")==1);
        assert(std::count(events.begin(),events.end(),"hardware-off")==0);
        assert(std::count(events.begin(),events.end(),"controller-off")==0);
        assert(events.back()=="icc-off");
    }
    fault=2; native_off_error=-EACCES; events.clear(); core.power.icc_bw=0;
    assert(iris_vpu_power_on(&core)==-EACCES && events.back()=="native-off");
    assert(std::count(events.begin(),events.end(),"icc-off")==0);
    native_off_error=0;
    fault=0; events.clear(); core.power.icc_bw=0;
    assert(iris_vpu_power_on(&core)==0);
    assert(std::count(events.begin(),events.end(),"irq-on")==0);
}
CPP
"${CXX:-g++}" -std=c++20 -O2 -Wall -Wextra -Werror \
    "$work/check.cpp" -o "$work/check"
"$work/check"
printf 'Actual Iris ICC cache, OPP failure/unwind and resume errno: passed\n'
