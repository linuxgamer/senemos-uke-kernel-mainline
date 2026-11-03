#!/usr/bin/env bash
# Host-only preparation; actual counters and ICC providers remain kernel-owned.
set -Eeuo pipefail
kernel=${1:?Pass the prepared kernel source}
here=$(cd -- "$(dirname -- "$0")" && pwd)
target=$kernel/drivers/soc/qcom
! grep -q QCOM_UKE_MEMLAT "$target/Kconfig"
install -m644 "$here/uke-memlat.c" "$here/uke-memlat-policy.h" "$target/"
install -m644 "$here/../boot/uke-memlat.h" "$kernel/arch/arm64/kernel/uke-memlat.h"
install -Dm644 "$here/xiaomi,uke-memlat.yaml" \
    "$kernel/Documentation/devicetree/bindings/soc/qcom/xiaomi,uke-memlat.yaml"
cat >> "$target/Kconfig" <<'KCONFIG'

config QCOM_UKE_MEMLAT
	bool "Uke LLCC/L3 memory-latency policy"
	depends on ARM64 && ARCH_QCOM && PERF_EVENTS && SMP && HOTPLUG_CPU
	depends on INTERCONNECT && QCOM_UKE_ABL_DT
	help
	  Sample native per-CPU PMU events against the inherited Uke LLCC/L3
	  frequency maps and vote through the standard interconnect providers.
	  Sampling is deferrable/freezable and releases votes during suspend.
	  This built-in consumer uses the kernel's scheduler idle snapshot.
	  DDR bandwidth monitoring and CPUCP firmware ownership are unchanged.
KCONFIG
printf '\nobj-$(CONFIG_QCOM_UKE_MEMLAT) += uke-memlat.o\n' >> "$target/Makefile"
