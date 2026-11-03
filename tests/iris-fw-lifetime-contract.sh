#!/usr/bin/env bash
# Fault-inject the actual core and PAS owner functions; no firmware is executed.
set -Eeuo pipefail
iris=${1:?Pass the prepared Iris directory}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/core.cpp" <<'CPP'
#include <cassert>
#include <cerrno>
enum { IRIS_CORE_DEINIT, IRIS_CORE_INIT, IRIS_CORE_ERROR, HW_RESPONSE_TIMEOUT_VALUE = 1000 };
struct iris_core;
struct firmware_data { void (*init_hfi_ops)(iris_core *); };
struct iris_core {
    void *dev{}; int lock{}, state{}, core_init_done{};
    bool fw_loaded{}, removing{}; void *fw_memory{};
    const firmware_data *iris_firmware_data{};
};
static unsigned queue_inits, queue_deinits, power_ons, power_offs, loads, shutdowns,
                waits, pm_gets, pm_puts, errors;
static int fault, shutdown_error, cleanup_error, power_error, pm_error, pm_refs;
static bool held_init_failure, locked;
static void mutex_lock(int *) { assert(!locked); locked = true; }
static void mutex_unlock(int *) { assert(locked); locked = false; }
#define dev_err(...) (++errors)
static int pm_runtime_resume_and_get(void *) {
    ++pm_gets; if (!pm_error) ++pm_refs; return pm_error;
}
static void pm_runtime_put_sync(void *) { ++pm_puts; assert(pm_refs > 0); --pm_refs; }
static void init_hfi_ops(iris_core *) {}
static const firmware_data data{init_hfi_ops};
static int iris_hfi_queues_init(iris_core *c) {
    ++queue_inits;
    if (fault == 1) { if (held_init_failure) c->fw_memory = c; return -ENOMEM; }
    c->fw_memory = c; return 0;
}
static int iris_hfi_queues_deinit(iris_core *c) {
    assert(!c->fw_loaded); ++queue_deinits;
    if (cleanup_error) return cleanup_error;
    c->fw_memory = nullptr; return 0;
}
static int iris_vpu_power_on(iris_core *) { ++power_ons; return fault == 2 ? -EREMOTEIO : 0; }
static int iris_vpu_power_off(iris_core *c) {
    assert(!c->fw_loaded); ++power_offs; return power_error;
}
static int iris_fw_load(iris_core *c) {
    ++loads; if (fault == 3) return -ENOENT;
    c->fw_loaded = true; c->iris_firmware_data = &data;
    return fault == 4 ? -EACCES : 0;
}
static int iris_fw_unload(iris_core *c) {
    if (!c->fw_loaded) return 0;
    ++shutdowns;
    if (shutdown_error) return shutdown_error;
    c->fw_loaded = false; return 0;
}
static int iris_vpu_boot_firmware(iris_core *) { return fault == 5 ? -ETIMEDOUT : 0; }
static int iris_vpu_switch_to_hwmode(iris_core *) { return fault == 6 ? -EIO : 0; }
static void iris_vpu_enable_irq(iris_core *) {}
static int iris_hfi_core_init(iris_core *) { return fault == 7 ? -EPIPE : 0; }
static unsigned msecs_to_jiffies(unsigned n) { return n; }
static unsigned wait_for_completion_timeout(int *, unsigned n) {
    assert(!locked && n == 1000); ++waits; return fault == 8 ? 0 : 1;
}
CPP
sed '/^#include /d' "$iris/iris_core.c" >> "$work/core.cpp"
cat >> "$work/core.cpp" <<'CPP'
static iris_core core;
static void reset(int selected = 0) {
    assert(!locked && pm_refs == 0);
    core = {}; fault = selected; shutdown_error = cleanup_error = power_error = pm_error = 0;
    held_init_failure = false;
    queue_inits = queue_deinits = power_ons = power_offs = loads = shutdowns = 0;
    waits = pm_gets = pm_puts = errors = 0;
}
int main() {
    reset(); core.removing = true;
    assert(iris_core_init(&core) == -ENODEV && !queue_inits && !power_ons);
    const int failures[]{0, -ENOMEM, -EREMOTEIO, -ENOENT, -EACCES, -ETIMEDOUT, -EIO, -EPIPE};
    for (int stage = 1; stage <= 7; ++stage) {
        reset(stage); assert(iris_core_init(&core) == failures[stage]);
        assert(!core.fw_loaded && !core.fw_memory && core.state == IRIS_CORE_DEINIT);
        assert(shutdowns == (stage >= 4 ? 1u : 0u));
        assert(power_offs == (stage >= 3 ? 1u : 0u));
    }
    reset(1); held_init_failure = true;
    assert(iris_core_init(&core) == -ENOMEM && core.state == IRIS_CORE_ERROR);
    iris_core_deinit(&core);
    assert(core.state == IRIS_CORE_DEINIT && !core.fw_memory && power_offs == 1 && !pm_refs);
    reset(); assert(iris_core_init(&core) == 0 && core.fw_loaded);
    assert(iris_core_init(&core) == 0 && queue_inits == 1);
    iris_core_deinit(&core);
    assert(core.state == IRIS_CORE_DEINIT && !core.fw_loaded && !core.fw_memory);
    assert(shutdowns == 1 && power_offs == 1 && queue_deinits == 1 && !pm_refs);
    iris_core_deinit(&core);
    assert(shutdowns == 1 && power_offs == 1 && queue_deinits == 1 && !pm_refs);
    reset(8); assert(iris_core_init(&core) == -ETIMEDOUT && core.fw_loaded);
    assert(core.state == IRIS_CORE_ERROR && core.fw_memory && !shutdowns);
    iris_core_deinit(&core); assert(!core.fw_memory && !core.fw_loaded && !pm_refs);
    reset(5); shutdown_error = -EREMOTEIO;
    assert(iris_core_init(&core) == -EREMOTEIO && core.state == IRIS_CORE_ERROR);
    assert(core.fw_loaded && core.fw_memory && !power_offs && !queue_deinits);
    assert(iris_core_init(&core) == -EINVAL && core.state == IRIS_CORE_ERROR && loads == 1);
    iris_core_deinit(&core); iris_core_deinit(&core);
    assert(core.fw_loaded && core.fw_memory && !power_offs && !queue_deinits && !pm_refs);
    shutdown_error = 0; iris_core_deinit(&core);
    assert(!core.fw_loaded && !core.fw_memory && power_offs == 1 && !pm_refs);
    reset(); assert(iris_core_init(&core) == 0); cleanup_error = -EIO;
    iris_core_deinit(&core);
    assert(!core.fw_loaded && core.fw_memory && core.state == IRIS_CORE_ERROR && power_offs == 1);
    cleanup_error = 0; iris_core_deinit(&core);
    assert(!core.fw_memory && power_offs == 2 && shutdowns == 1 && !pm_refs);
    reset(5); power_error = -EREMOTEIO;
    assert(iris_core_init(&core) == -EREMOTEIO && !core.fw_loaded && core.fw_memory);
    assert(core.state == IRIS_CORE_ERROR && !queue_deinits && shutdowns == 1);
    iris_core_deinit(&core);
    assert(core.fw_memory && !queue_deinits && power_offs == 2 && !pm_refs);
    power_error = 0; iris_core_deinit(&core);
    assert(!core.fw_memory && queue_deinits == 1 && power_offs == 3 && shutdowns == 1);
    reset(); assert(iris_core_init(&core) == 0); pm_error = -EREMOTEIO;
    iris_core_deinit(&core);
    assert(core.fw_loaded && core.fw_memory && !shutdowns && !power_offs && !queue_deinits);
    assert(core.state == IRIS_CORE_ERROR && !pm_refs && !pm_puts);
    pm_error = 0; iris_core_deinit(&core); assert(!core.fw_memory && !pm_refs);
}
CPP
cat > "$work/pas.cpp" <<'CPP'
#include <cassert>
#include <cerrno>
#include <cstdint>
#define IRIS_PAS_ID 9
struct tz_cp_config { unsigned cp_start, cp_size, cp_nonpixel_start, cp_nonpixel_size; };
struct platform { unsigned tz_cp_config_data_size; const tz_cp_config *tz_cp_config_data; };
struct iris_core { void *dev; bool fw_loaded; const platform *iris_platform_data; };
static int download_error, auth_error, protect_error, shutdown_error;
static unsigned downloads, auths, protects, stops;
struct firmware {};
static const firmware available_firmware{};
static int available_error;
static unsigned availability_checks, firmware_releases;
#define IS_ERR(ptr) (reinterpret_cast<intptr_t>(ptr) < 0)
#define PTR_ERR(ptr) static_cast<int>(reinterpret_cast<intptr_t>(ptr))
static const firmware *iris_detect_firmware(iris_core *, const char **) {
    ++availability_checks;
    return available_error ? reinterpret_cast<const firmware *>(static_cast<intptr_t>(available_error)) : &available_firmware;
}
static void release_firmware(const firmware *fw) { assert(fw==&available_firmware); ++firmware_releases; }
static int iris_load_fw_to_memory(iris_core *) { ++downloads; return download_error; }
static int qcom_pas_auth_and_reset(int id) { assert(id == 9); ++auths; return auth_error; }
static int qcom_scm_mem_protect_video_var(unsigned, unsigned, unsigned, unsigned) {
    ++protects; return protect_error;
}
static int qcom_pas_shutdown(int id) { assert(id == 9); ++stops; return shutdown_error; }
#define dev_err(...) ((void)0)
CPP
for function in iris_fw_check_available iris_fw_load iris_fw_unload; do
    awk -v name="$function" '$0 ~ "^int " name "\\(" {emit=1} emit {print} emit && /^}/ {exit}' \
        "$iris/iris_firmware.c" >> "$work/pas.cpp"
done
cat >> "$work/pas.cpp" <<'CPP'
int main() {
    tz_cp_config config{}; platform data{1, &config}; iris_core core{nullptr, false, &data};
    available_error=-ENOENT;
    assert(iris_fw_check_available(&core)==-ENOENT && availability_checks==1 && !firmware_releases);
    assert(!downloads && !auths && !protects && !stops && !core.fw_loaded);
    available_error=0;
    assert(iris_fw_check_available(&core)==0 && availability_checks==2 && firmware_releases==1);
    assert(!downloads && !auths && !protects && !stops && !core.fw_loaded);
    assert(iris_fw_unload(&core) == 0 && !stops);
    download_error = -ENOENT;
    assert(iris_fw_load(&core) == -ENOENT && !auths && !core.fw_loaded);
    download_error = 0; auth_error = -EACCES;
    assert(iris_fw_load(&core) == -EACCES && !protects && !core.fw_loaded);
    auth_error = 0; protect_error = -EREMOTEIO;
    assert(iris_fw_load(&core) == -EREMOTEIO && core.fw_loaded && !stops);
    assert(iris_fw_load(&core) == -EBUSY && downloads == 3 && auths == 2);
    shutdown_error = -EIO;
    assert(iris_fw_unload(&core) == -EIO && core.fw_loaded && stops == 1);
    shutdown_error = 0;
    assert(iris_fw_unload(&core) == 0 && !core.fw_loaded && stops == 2);
    protect_error = 0;
    assert(iris_fw_load(&core) == 0 && core.fw_loaded);
    assert(iris_fw_unload(&core) == 0 && !core.fw_loaded && stops == 3);
}
CPP
for fixture in core pas; do
    "${CXX:-g++}" -std=c++20 -O2 -Wall -Wextra -Werror -Wno-sign-compare \
        "$work/$fixture.cpp" -o "$work/$fixture"
    "$work/$fixture"
done
printf 'Actual core/PAS owner: init faults, shutdown retention, PM balance and safe cleanup retries passed\n'
