#!/usr/bin/env bash
# Actual native domain setup with host-only attachment failure stubs.
set -Eeuo pipefail
iris=${1:?Pass the prepared Iris directory}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cerrno>
#include <cstring>
struct device { void *of_node; };
struct dev_pm_domain_attach_data {
    const char * const *pd_names;
    unsigned num_pd_names, pd_flags;
};
struct dev_pm_opp_config { const char * const *clk_names; void (*config_clks)(); };
struct platform {
    const char * const *pmdomain_tbl;
    unsigned pmdomain_tbl_size;
    const char * const *opp_pd_tbl;
    unsigned opp_pd_tbl_size;
    const char * const *opp_clk_tbl;
};
struct iris_core { device *dev; platform *iris_platform_data; void *pmdomain_tbl, *opp_pmdomain_tbl; };
constexpr unsigned PD_FLAG_NO_DEV_LINK=1, PD_FLAG_DEV_LINK_ON=2, PD_FLAG_REQUIRED_OPP=4;
static void dev_pm_opp_config_clks_simple() {}
static unsigned calls, config_calls, table_calls, failure;
static bool legacy;
static int devm_pm_domain_attach_list(device *, dev_pm_domain_attach_data *data, void **) {
    assert(data->pd_names && data->num_pd_names);
    ++calls;
    if (legacy && calls==2) return -ENODEV;
    return calls==failure ? -EREMOTEIO : static_cast<int>(data->num_pd_names);
}
static bool of_device_is_compatible(void *, const char *name) { return legacy && !strcmp(name,"qcom,sm8250-venus"); }
static int devm_pm_opp_set_config(device *, dev_pm_opp_config *config) {
    assert(config->clk_names); ++config_calls; return failure==3 ? -EINVAL : 0;
}
static int devm_pm_opp_of_add_table(device *) { ++table_calls; return failure==4 ? -ENOENT : 0; }
CPP
awk '/^static int iris_init_power_domains\(/ { emit=1 } emit { print } emit && /^}/ { exit }' \
    "$iris/iris_probe.c" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
static int run(unsigned opp_count, unsigned fault=0, bool old=false) {
    static const char *pd[]{"venus","vcodec0"}, *opp[]{"mxc","mmcx"}, *clk[]{"vcodec0_core",nullptr};
    platform data{pd,2,opp_count ? opp : nullptr,opp_count,clk};
    device dev{nullptr}; iris_core core{&dev,&data,nullptr,nullptr};
    calls=config_calls=table_calls=0; failure=fault; legacy=old;
    return iris_init_power_domains(&core);
}
int main() {
    assert(run(0)==0 && calls==1 && config_calls==1 && table_calls==1);
    assert(run(2)==0 && calls==2 && config_calls==1 && table_calls==1);
    assert(run(2,1)==-EREMOTEIO && calls==1 && !config_calls);
    assert(run(2,2)==-EREMOTEIO && calls==2 && !config_calls);
    assert(run(0,3)==-EINVAL && calls==1 && !table_calls);
    assert(run(0,4)==-ENOENT && table_calls==1);
    assert(run(2,0,true)==0 && calls==3 && config_calls==1);
}
CPP
"${CXX:-g++}" -std=c++20 -O2 -Wall -Wextra -Werror "$work/check.cpp" -o "$work/check"
"$work/check"
printf 'Actual Iris domain setup: regulator path, native/legacy and error cases passed\n'
