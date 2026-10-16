# Uke Linux 7.2.10 adaptation

The 40 patches carry the reviewed 7.2.9 adaptation, including the experimental
Adreno 732 catalog and NoC graph, onto the signed upstream 7.2.10 source. Every
patch retains its source attribution and manifest hash. No generic ARM64 fallback
or foreign-device firmware is admitted.

The additional patches connect firmware-display metadata, correct unbound
Adreno removal and preserve SM7675 EPSS operating points for the single-core
Prime domain. The stock-ABL GPU overlay separately supplies nine SM7675
frequency/corner/bandwidth points. Native DPU/DSI work remains an isolated
candidate under `src/display/`; it is not enabled by this release series.

Tablet graphics results come from the separately tested 7.2.9 installation.
The 7.2.10 adaptation still needs its own source application, build, package
checks and matched tablet boot. Early GPU probing, full DVFS, thermal limits
and suspend remain open; the independent Uke DTS and stock-ABL handoff are
different boot paths.
