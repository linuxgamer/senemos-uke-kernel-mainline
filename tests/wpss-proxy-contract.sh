#!/usr/bin/env bash
# Host fault injection into the prepared PAS functions; no firmware/device writes.
set -Eeuo pipefail
source_file=${1:?Pass the Wi-Fi-patched qcom_q6v5_pas.c}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
{
    cat <<'CPP'
#include <cassert>
#include <cerrno>
#include <climits>
#include <cstring>
#include <iterator>
#include <cstdint>
#define ARRAY_SIZE(a) std::size(a)
#define BIT(n) (1U << (n))
#define IS_ERR(p) false
#define PTR_ERR(p) (-ENODEV)
constexpr int turbo = 384;
struct regulator { int vote = 0, load = 0, refs = 0; bool enabled = false; };
struct regulator_bulk_data { const char *supply; regulator *consumer; };
struct device { bool cx = true, mx = true, nsp = true; void *of_node = this; };
struct qcom_pas {
    device *dev;
    device *proxy_pds[3] {};
    unsigned int proxy_pd_count = 0, proxy_regulator_level = turbo;
    unsigned int proxy_regulator_count = 2, proxy_regulator_load = 0;
    regulator_bulk_data proxy_regs[3] {};
    uint8_t proxy_voltage_mask = 0, proxy_load_mask = 0;
    bool proxy_regs_enabled = false; // Retained to reproduce the old bulk path.
    uint8_t proxy_enable_mask = 0;
    int proxy_error = 0;
    regulator *cx_supply = nullptr, *px_supply = nullptr;
};
struct qcom_pas_data {
    unsigned int proxy_regulator_level, proxy_regulator_count, proxy_regulator_load;
};
regulator rails[3];
int fail_vote = -1, bulk_error = 0, get_error = 0, errors = 0, gets = 0;
int fail_load = -1, fail_unvote = -1, fail_unload = -1, enable_calls = 0, disable_calls = 0;
int fail_enable = -1, fail_disable = -1;
int pd_gets = 0, pd_puts = 0;
bool of_property_present(void *node, const char *name) {
    auto *d = static_cast<device *>(node);
    if (!std::strcmp(name, "cx-supply")) return d->cx;
    if (!std::strcmp(name, "mx-supply")) return d->mx;
    assert(!std::strcmp(name, "nsp-supply")); return d->nsp;
}
int dev_err_probe(device *, int error, const char *, ...) { return error; }
template<class... T> void dev_err(device *, const char *, T...) { ++errors; }
int regulator_set_voltage(regulator *r, int value, int maximum) {
    assert(maximum == INT_MAX);
    if ((value && r - rails == fail_vote) || (!value && r - rails == fail_unvote)) return -EIO;
    if (!value) assert(!r->refs);
    r->vote = value;
    return 0;
}
int regulator_enable(regulator *r) {
    ++enable_calls;
    if (bulk_error || r-rails==fail_enable) return -EIO;
    assert(!r->refs); r->enabled=true; ++r->refs;
    return 0;
}
int regulator_disable(regulator *r) {
    ++disable_calls;
    if (bulk_error || r-rails==fail_disable) return -EIO;
    assert(r->refs==1); r->enabled=false; --r->refs;
    return 0;
}
// Model core.c's bulk rollback, including its ignored secondary failures.
int regulator_bulk_enable(int count, regulator_bulk_data *regs) {
    int results[3],error=0;
    for(int i=0;i<count;i++) { results[i]=regulator_enable(regs[i].consumer); if(!error) error=results[i]; }
    if(error) for(int i=0;i<count;i++) if(!results[i]) regulator_disable(regs[i].consumer);
    return error;
}
int regulator_bulk_disable(int count, regulator_bulk_data *regs) {
    for(int i=count-1;i>=0;i--) {
        int ret=regulator_disable(regs[i].consumer);
        if(ret) { for(++i;i<count;i++) regulator_enable(regs[i].consumer); return ret; }
    }
    return 0;
}
int devm_regulator_bulk_get(device *, int count, regulator_bulk_data *regs) {
    ++gets;
    if (get_error) return get_error;
    assert((count == 2 || count == 3) && !std::strcmp(regs[0].supply, "cx") && !std::strcmp(regs[1].supply, "mx"));
    if (count == 3) assert(!std::strcmp(regs[2].supply, "nsp"));
    for (int i = 0; i < count; ++i) regs[i].consumer = &rails[i];
    return 0;
}
regulator *devm_regulator_get_optional(device *, const char *) { return nullptr; }
int regulator_set_load(regulator *r, int value) {
    if ((value && r - rails == fail_load) || (!value && r - rails == fail_unload)) return -EIO;
    r->load = value; return 0;
}
void dev_pm_genpd_set_performance_state(device *, int) {}
int pm_runtime_get_sync(device *) { ++pd_gets; return 0; }
void pm_runtime_put(device *) { ++pd_puts; }
void pm_runtime_put_noidle(device *) {}
CPP
    awk '/^static (int|void) qcom_pas_proxy_unvote/ { emit=1 } /^static int qcom_pas_shutdown_poll_decrypt/ { emit=0 } emit { print }' "$source_file"
    awk '/^static int qcom_pas_init_regulator/ { emit=1 } /^static int qcom_pas_pds_attach/ { emit=0 } emit { print }' "$source_file"
    printf 'static void descriptor_votes(qcom_pas *pas, const qcom_pas_data *desc) {\n'
    awk '/^[[:space:]]+pas->proxy_regulator_(level|count|load) = desc->proxy_regulator_/ {print}' "$source_file"
    printf '}\n'
    cat <<'CPP'
int main() {
    device dev;
    qcom_pas pas{&dev};
    qcom_pas_data desc{turbo,0,0};
    descriptor_votes(&pas,&desc);
    assert(pas.proxy_regulator_level==turbo && pas.proxy_regulator_count==2 && !pas.proxy_regulator_load);
    desc.proxy_regulator_count=3; desc.proxy_regulator_load=100000;
    descriptor_votes(&pas,&desc);
    assert(pas.proxy_regulator_count==3 && pas.proxy_regulator_load==100000);
    for (unsigned int invalid : {0U, 1U, 4U}) {
        pas.proxy_regulator_count = invalid;
        assert(qcom_pas_init_regulator(&pas) == -EINVAL && gets == 0);
    }
    for (unsigned int count : {2U, 3U}) {
        pas.proxy_regulator_count = count;
        pas.proxy_regulator_load = count == 3 ? 100000 : 0;
        gets = 0;
        for (unsigned int missing = 0; missing < count; ++missing) {
            dev.cx = missing != 0; dev.mx = missing != 1; dev.nsp = missing != 2;
            assert(qcom_pas_init_regulator(&pas) == -EINVAL && gets == 0);
        }
        dev.cx = dev.mx = dev.nsp = true;
        get_error = -517;
        assert(qcom_pas_init_regulator(&pas) == -517);
        get_error = 0;
        assert(qcom_pas_init_regulator(&pas) == 0);
        auto clean = [&] {
            assert(!pas.proxy_error);
            assert(!pas.proxy_enable_mask && !pas.proxy_voltage_mask && !pas.proxy_load_mask);
            for (const auto &r : rails) assert(!r.enabled && !r.refs && !r.vote && !r.load);
        };
        fail_enable=1; fail_disable=0;
        assert(qcom_pas_proxy_enable(&pas)==-EIO);
        assert(rails[0].refs==1 && rails[0].vote==turbo && pas.proxy_enable_mask==BIT(0));
        fail_enable=fail_disable=-1;
        assert(qcom_pas_proxy_enable(&pas)==0 && pas.proxy_enable_mask==BIT(count)-1);
        for(unsigned int i=0;i<count;i++) assert(rails[i].refs==1);
        assert(qcom_pas_proxy_disable(&pas)==0); clean();
        assert(qcom_pas_proxy_enable(&pas)==0);
        fail_disable=0; fail_enable=static_cast<int>(count-1);
        assert(qcom_pas_proxy_disable(&pas)==-EIO);
        assert(pas.proxy_enable_mask==BIT(0) && rails[0].refs==1 && rails[count-1].refs==0);
        fail_enable=fail_disable=-1; assert(qcom_pas_proxy_disable(&pas)==0); clean();
        for (unsigned int stage = 0; stage <= count; ++stage) {
            fail_vote = stage < count ? static_cast<int>(stage) : -1;
            bulk_error = stage == count ? -EIO : 0;
            assert(qcom_pas_proxy_enable(&pas) == -EIO); clean();
        }
        fail_vote = -1; bulk_error = 0;
        if (count == 3) for (int stage = 0; stage < 3; ++stage) {
            fail_load = stage;
            assert(qcom_pas_proxy_enable(&pas) == -EIO); clean();
        }
        fail_load = -1; enable_calls = disable_calls = errors = 0;
        assert(qcom_pas_proxy_enable(&pas) == 0 && enable_calls == static_cast<int>(count));
        assert(qcom_pas_proxy_enable(&pas) == 0 && enable_calls == static_cast<int>(count));
        bulk_error = -EIO;
        assert(qcom_pas_proxy_disable(&pas)==-EIO && pas.proxy_error==-EIO);
        assert(errors == static_cast<int>(count) && pas.proxy_enable_mask == BIT(count)-1);
        for (unsigned int i = 0; i < count; ++i)
            assert(rails[i].refs == 1 && rails[i].vote == turbo && rails[i].load == static_cast<int>(pas.proxy_regulator_load));
        assert(qcom_pas_proxy_enable(&pas) == 0 && enable_calls == static_cast<int>(count));
        bulk_error = 0;
        qcom_pas_proxy_disable(&pas); clean();
        qcom_pas_proxy_disable(&pas); clean();
        assert(disable_calls == static_cast<int>(2*count));
        for (unsigned int stage = 0; stage < count; ++stage) {
            assert(qcom_pas_proxy_enable(&pas) == 0);
            fail_unvote = static_cast<int>(stage);
            assert(qcom_pas_proxy_disable(&pas)==-EIO && pas.proxy_error==-EIO);
            assert(!pas.proxy_enable_mask && pas.proxy_voltage_mask == BIT(stage));
            assert(rails[stage].vote == turbo && !rails[stage].refs);
            const int disabled = disable_calls;
            fail_unvote = -1;
            qcom_pas_proxy_disable(&pas); clean();
            assert(disable_calls == disabled);
        }
        if (count == 3) for (int stage = 0; stage < 3; ++stage) {
            assert(qcom_pas_proxy_enable(&pas) == 0);
            fail_unload = stage;
            assert(qcom_pas_proxy_disable(&pas)==-EIO && pas.proxy_error==-EIO);
            assert(!pas.proxy_enable_mask && pas.proxy_load_mask == BIT(stage));
            assert(rails[stage].load == 100000 && !rails[stage].refs);
            fail_unload = -1;
            qcom_pas_proxy_disable(&pas); clean();
        }
    }
    pas.proxy_regulator_level = 0; pas.proxy_pd_count = 2;
    assert(qcom_pas_init_regulator(&pas) == 0);
    assert(qcom_pas_proxy_enable(&pas) == 0 && pd_gets == 2);
    qcom_pas_proxy_disable(&pas);
    assert(pd_puts == 2);
}
CPP
} > "$work/check.cpp"
grep -F 'Cliffs PAS requires AOP load-state QMP' "$source_file" >/dev/null
grep -F '"qcom,cliffs-wpss-pas", .data = &cliffs_wpss_resource' "$source_file" >/dev/null
awk '/^static const struct qcom_pas_data cliffs_wpss_resource/ { emit=1 } emit { print } emit && /^};/ { exit }' "$source_file" > "$work/match"
for value in '.crash_reason_smem = 626' '.pas_id = 6' '.minidump_id = 4' '.auto_boot = false' '.ssctl_id = 0x19' '.proxy_regulator_level = RPMH_REGULATOR_LEVEL_TURBO'; do
    grep -F "$value" "$work/match" >/dev/null
done
grep -F '"qcom,cliffs-adsp-pas", .data = &cliffs_adsp_resource' "$source_file" >/dev/null
awk '/^static const struct qcom_pas_data cliffs_adsp_resource/ { emit=1 } emit { print } emit && /^};/ { exit }' "$source_file" > "$work/adsp-match"
for value in '.crash_reason_smem = 423' '.firmware_name = "adsp.mdt"' '.dtb_firmware_name = "adsp_dtb.mdt"' '.pas_id = 1,' '.dtb_pas_id = 0x24' '.minidump_id = 5' '.auto_boot = false' '.load_state = "adsp"' '.ssr_name = "lpass"' '.ssctl_id = 0x14' '.smem_host_id = 2' '.proxy_regulator_level = RPMH_REGULATOR_LEVEL_TURBO'; do
    grep -F "$value" "$work/adsp-match" >/dev/null
done
flags=(-std=c++20 -O2 -Wall -Wextra -Werror)
if [[ ${SANITIZE:-0} == 1 ]]; then
    flags+=(-O1 -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer)
fi
"${CXX:-g++}" "${flags[@]}" "$work/check.cpp" -o "$work/check"
"$work/check"
printf 'Cliffs proxy: two/three supplies, load/vote/enable/disable faults, retained ownership, retry, descriptors and legacy genpd: passed\n'
