#!/usr/bin/env bash
# Exercise the actual helper and delayed driver-core cleanup after core free.
set -Eeuo pipefail
kernel=${1:?Pass prepared kernel}
baseline=${2:-}
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
cat > "$work/prefix.cpp" <<'CPP'
#include <cassert>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <vector>
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
constexpr int EPROBE_DEFER=517;
struct regulator { int puts=0; };
struct regulator_bulk_data { const char* supply=nullptr;regulator* consumer=nullptr; };
struct node { bool compatible=true;int missing=-1; };
struct device {
    node* of_node;int get_error=0;bool allocation_failure=false;
    regulator handles[3];regulator_bulk_data* callback=nullptr;
    std::vector<regulator_bulk_data*> managed;
};
struct ath11k_ahb {regulator_bulk_data uke_regs[3];bool uke_supplies=false;};
struct ath11k_base {device* dev;ath11k_ahb ahb;};
ath11k_ahb* ath11k_ahb_priv(ath11k_base* ab){return &ab->ahb;}
bool of_device_is_compatible(node* n,const char*){return n->compatible;}
bool of_property_present(node* n,const char* property) {
    const char* names[]{"vdd-cx-mx-supply","vdd-1.8-xo-supply","vdd-1.3-rfa-supply"};
    for(int i=0;i<3;i++)if(std::strcmp(property,names[i])==0)return n->missing!=i;
    assert(false);return false;
}
int dev_err_probe(device*,int error,const char*,...){return error;}
int devm_regulator_bulk_get(device* dev,int count,regulator_bulk_data* data) {
    assert(count==3);if(dev->get_error)return dev->get_error;
    for(int i=0;i<count;i++)data[i].consumer=&dev->handles[i];
    dev->callback=data;return 0;
}
int devm_regulator_bulk_get_const(device* dev,int count,const regulator_bulk_data* input,regulator_bulk_data** out) {
    if(dev->allocation_failure)return -ENOMEM;
    *out=new regulator_bulk_data[count];std::memcpy(*out,input,count*sizeof(**out));
    dev->managed.push_back(*out);return devm_regulator_bulk_get(dev,count,*out);
}
void devres_release_all(device& dev) {
    if(dev.callback)for(int i=0;i<3;i++) {
        assert(dev.callback[i].consumer==&dev.handles[i]);
        dev.callback[i].consumer->puts++;
    }
    for(auto* array:dev.managed)delete[] array;
}
CPP
cat > "$work/suffix.cpp" <<'CPP'
int main() {
    for(bool compatible:{false,true})for(int missing:{-1,0,1,2})
    for(int error:{0,-ENOMEM,-EPROBE_DEFER})for(bool allocation_failure:{false,true}) {
        node n{compatible,missing};device dev{};dev.of_node=&n;
        dev.get_error=error;dev.allocation_failure=allocation_failure;
        auto* ab=new ath11k_base{};ab->dev=&dev;
        const int ret=ath11k_ahb_uke_regulators(ab);
        const int expected=!compatible?0:missing>=0?-EINVAL:allocation_failure?-ENOMEM:error;
        assert(ret==expected);
        const bool acquired=compatible&&ret==0;
        assert(ab->ahb.uke_supplies==acquired);
        if(acquired)for(int i=0;i<3;i++)assert(ab->ahb.uke_regs[i].consumer==&dev.handles[i]);
        delete ab;
        devres_release_all(dev);
        for(const auto& handle:dev.handles)assert(handle.puts==(acquired?1:0));
    }
    puts("Actual Uke WLAN helper: deferred probe/core-free/devres ordering, allocation/get failures, mandatory supplies and foreign boards passed; host only");
}
CPP
compile() {
    cat "$work/prefix.cpp" > "$work/$2.cpp"
    awk '/^static int ath11k_ahb_uke_regulators\(/ {emit=1} emit{print} emit&&/^}/ {exit}' "$1/drivers/net/wireless/ath/ath11k/ahb.c" >> "$work/$2.cpp"
    cat "$work/suffix.cpp" >> "$work/$2.cpp"
    "${CXX:-g++}" -std=c++20 -O1 -g -Wall -Wextra -Werror -Wno-sign-compare -fsanitize=address,undefined -fno-omit-frame-pointer "$work/$2.cpp" -o "$work/$2"
}
compile "$kernel" fixed
ASAN_OPTIONS=detect_leaks=1 "$work/fixed"
if [[ -n $baseline ]]; then
    compile "$baseline" original
    # The original helper has no independent-array allocation failure case.
    sed -i 's/for(bool allocation_failure:{false,true})/for(bool allocation_failure:{false})/' "$work/original.cpp"
    "${CXX:-g++}" -std=c++20 -O1 -g -fsanitize=address -fno-omit-frame-pointer "$work/original.cpp" -o "$work/original"
    if ASAN_OPTIONS=detect_leaks=0 "$work/original" > "$work/old.log" 2>&1; then
        echo 'Original delayed cleanup unexpectedly passed' >&2;exit 1
    fi
    grep -q 'heap-use-after-free' "$work/old.log"
    printf 'Unmodified baseline reproduces heap-use-after-free after core free.\n'
fi
