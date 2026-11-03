#!/usr/bin/env bash
# Verify the actual configured and linked provider in the remote kernel output.
set -Eeuo pipefail
output=${1:?Pass the actual kernel output directory}
grep -Fxq CONFIG_QCOM_UKE_MEMLAT=m "$output/.config"
module=$output/drivers/soc/qcom/uke-memlat.ko
test -s "$module"
modinfo -F alias "$module" | grep -Fx 'of:N*T*Cxiaomi,uke-memlatC*'
printf 'Uke MEMLAT linked module, configured policy and exact OF alias verified; hardware untested\n'
