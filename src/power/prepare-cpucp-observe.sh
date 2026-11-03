#!/usr/bin/env bash
# Host-only source preparation; the signed module requires explicit loading.
set -Eeuo pipefail
kernel=${1:?Pass the prepared kernel source}
here=$(cd -- "$(dirname -- "$0")" && pwd)
target=$kernel/drivers/firmware/arm_scmi
test -f "$target/protocols.h"
! grep -q QCOM_UKE_CPUCP_OBSERVE "$target/Kconfig"
install -m644 "$here/uke-cpucp-observe.c" "$target/uke-cpucp-observe.c"
cat >> "$target/Kconfig" <<'KCONFIG'

config QCOM_UKE_CPUCP_OBSERVE
	tristate "Read-only Uke CPUCP protocol observer"
	depends on ARM64 && ARM_SCMI_PROTOCOL && QCOM_UKE_ABL_DT
	help
	  Manually loaded diagnostic for the exact Uke MEMLAT timestamp,
	  raw frequency and C1DCVS enable GET contracts. No firmware
	  configuration or performance policy is changed. No autoload alias.
KCONFIG
printf '\nobj-$(CONFIG_QCOM_UKE_CPUCP_OBSERVE) += uke-cpucp-observe.o\n' >> "$target/Makefile"
bash "$here/../../tests/memlat-scmi-probe-contract.sh" "$target/uke-cpucp-observe.c"
