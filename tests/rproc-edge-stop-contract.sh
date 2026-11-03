#!/usr/bin/env bash
# Actual GLINK/SMD subdevice stops; transport removal is mocked, never run on target.
set -Eeuo pipefail
source_file=${1:?Pass the prepared qcom_common.c}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cstdint>
#include <cstddef>
#include <cerrno>
#define IS_ERR_OR_NULL(p) (!(p) || (uintptr_t)(p)>=(uintptr_t)-4095)
struct rproc_subdev { void *owner; };
struct qcom_glink_smem { bool removed=false; };
struct qcom_rproc_glink { rproc_subdev subdev{this}; qcom_glink_smem *edge=nullptr; };
struct qcom_rproc_subdev { rproc_subdev subdev{this}; qcom_glink_smem *edge=nullptr; };
static unsigned int removals;
static qcom_rproc_glink *to_glink_subdev(rproc_subdev *subdev) { return static_cast<qcom_rproc_glink *>(subdev->owner); }
static qcom_rproc_subdev *to_smd_subdev(rproc_subdev *subdev) { return static_cast<qcom_rproc_subdev *>(subdev->owner); }
static void qcom_glink_smem_unregister(qcom_glink_smem *edge) {
    assert(!IS_ERR_OR_NULL(edge) && !edge->removed); edge->removed=true; ++removals;
}
static void qcom_smd_unregister_edge(qcom_glink_smem *edge) { qcom_glink_smem_unregister(edge); }
CPP
awk '/^static void (glink|smd)_subdev_stop\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$source_file" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
template<class T> void check(void (*stop)(rproc_subdev *,bool)) {
    T glink; removals=0;
    for (bool crashed : {false,true}) {
        stop(&glink.subdev,crashed); assert(!removals && !glink.edge);
        for (int error : {-ENOMEM,-EPROBE_DEFER}) {
            glink.edge=(qcom_glink_smem *)(intptr_t)error;
            stop(&glink.subdev,crashed); assert(!removals && !glink.edge);
        }
    }
    for (bool crashed : {false,true}) {
        qcom_glink_smem edge; glink.edge=&edge; unsigned int before=removals;
        stop(&glink.subdev,crashed);
        assert(removals==before+1 && edge.removed && !glink.edge);
        // The core can retry stop after the PAS callback reports a failure.
        stop(&glink.subdev,crashed);
        assert(removals==before+1 && !glink.edge);
    }
}
int main() { check<qcom_rproc_glink>(glink_subdev_stop); check<qcom_rproc_subdev>(smd_subdev_stop); }
CPP
# Upstream's callback ABI includes an intentionally unused crash flag.
flags=(-std=c++20 -O2 -Wall -Wextra -Werror -Wno-unused-parameter -include initializer_list -DEPROBE_DEFER=517)
if [[ ${SANITIZE:-0} == 1 ]]; then
    flags+=(-O1 -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer)
fi
"${CXX:-g++}" "${flags[@]}" "$work/check.cpp" -o "$work/check"
"$work/check"
printf 'Actual GLINK/SMD stops: missing/failed edge, normal/crash shutdown and repeated transport removal passed\n'
