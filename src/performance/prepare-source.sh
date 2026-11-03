#!/usr/bin/env bash
# Install the native, count-only LLCC perf provider; no firmware policy owner.
set -Eeuo pipefail
kernel=${1:?Pass prepared Linux source}
here=$(cd -- "$(dirname -- "$0")" && pwd)
! grep -q QCOM_SM7675_LLCC_PMU "$kernel/drivers/perf/Kconfig"
install -m644 "$here/qcom-sm7675-llcc-pmu.c" "$kernel/drivers/perf/qcom-sm7675-llcc-pmu.c"
install -Dm644 "$here/qcom,sm7675-llcc-pmu.yaml" \
    "$kernel/Documentation/devicetree/bindings/perf/qcom,sm7675-llcc-pmu.yaml"
cat >> "$kernel/drivers/perf/Kconfig" <<'KCONFIG'

config QCOM_SM7675_LLCC_PMU
	tristate "Qualcomm SM7675 LLCC read counters"
	depends on ARM64 && ARCH_QCOM && PERF_EVENTS && CPU_PM
	help
	  Count-only per-CPU LLCC-v2 events on SM7675. Counter units and
	  the polling wrap bound require platform measurement before policy use.
KCONFIG
printf '\nobj-$(CONFIG_QCOM_SM7675_LLCC_PMU) += qcom-sm7675-llcc-pmu.o\n' >> "$kernel/drivers/perf/Makefile"
