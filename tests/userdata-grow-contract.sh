#!/usr/bin/env bash
# Host-only native geometry and refusal checks; no block device is opened.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/test.cpp" <<'EOF'
#include "userdata-grow.hpp"
#include <cassert>
using namespace uke::userdata;
static void set(Header &h, unsigned offset, unsigned size, std::uint64_t value) {
    for (unsigned i = 0; i < size; ++i) h.at(offset + i) = (value >> (8 * i)) & 255;
}
template<class Call> static void reject(Call call) {
    bool refused = false;
    try { call(); } catch (const std::exception &) { refused = true; }
    assert(refused);
}
int main() {
    constexpr std::uint64_t gib = 1024ULL * 1024 * 1024;
    Header h{};
    set(h, 0, 4, 0xf2f52010); set(h, 8, 4, 9); set(h, 12, 4, 3);
    set(h, 16, 4, 12); set(h, 20, 4, 9); set(h, 24, 4, 1); set(h, 28, 4, 1);
    set(h, 36, 8, 2 * gib / 4096); h[108] = 1;
    constexpr std::string_view label = "UKE_LINUX";
    for (unsigned i = 0; i < label.size(); ++i) h[124 + 2 * i] = label[i];
    assert(filesystem_bytes(h, h, 8 * gib) == 2 * gib);
    assert(needs_growth(h, h, 8 * gib));
    assert(!needs_growth(h, h, 2 * gib));
    assert(!needs_growth(h, h, 2 * gib + 4096));
    reject([&] { filesystem_bytes(h, h, gib); });
    reject([&] { filesystem_bytes(h, h, 8 * gib + 1); });
    for (unsigned index : {0U, 16U, 20U, 24U, 28U, 108U, 124U, 125U, 142U, 143U}) {
        auto bad = h; bad[index] ^= 1;
        reject([&] { filesystem_bytes(bad, h, 8 * gib); });
        reject([&] { filesystem_bytes(bad, bad, 8 * gib); });
    }
    for (auto count : std::array<std::uint64_t, 3>{0, 32767, UINT64_MAX}) {
        auto bad = h; set(bad, 36, 8, count);
        reject([&] { filesystem_bytes(bad, bad, 8 * gib); });
    }
    auto full = h; set(full, 36, 8, 8 * gib / 4096);
    assert(!needs_growth(full, full, 8 * gib));
}
EOF
c++ -std=c++17 -Wall -Wextra -Werror -I "$root/src/boot" "$work/test.cpp" -o "$work/test"
"$work/test"
c++ -std=c++17 -O2 -Wall -Wextra -Werror "$root/src/boot/userdata-grow.cpp" -o "$work/userdata-grow"
for mode in run condition; do
    arguments=(/dev/null)
    [[ $mode != condition ]] || arguments=(--needed /dev/null)
    status=0
    "$work/userdata-grow" "${arguments[@]}" > "$work/refusal" 2>&1 || status=$?
    [[ $status == 255 ]] || { echo 'Invalid initrd invocation was not a hard failure' >&2; exit 1; }
    grep -Fq UKE_USERDATA_GROW_REJECTED "$work/refusal"
done
grep -Fxq 'RemainAfterExit=yes' "$root/src/boot/dracut/uke-userdata-grow.service"
! grep -q '^ExecCondition=' "$root/src/boot/dracut/uke-userdata-grow.service"
printf '%s\n' 'F2FS copy/identity/size, completed-growth skip and native refusal fixtures passed; no storage write.'
