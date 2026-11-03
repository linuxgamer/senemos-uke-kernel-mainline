# Uke secure RTC candidate

3 November 2026. The retained 7.3.1-1500 production source is extended as
7.3.1-1600. Source and native fixtures do not establish physical RTC persistence.
Use the COPR producer `packaging/native/copr-rtc1600.sh`; compilation runs on
the Fedora Rawhide AArch64 worker. Do not build or flash this tree on a tablet.

The measured Uke PMIC counter advances but its current RTC calendar remains
in 1970. OEM sources do not authorize direct host counter writes. The running
firmware advertises QSEECom version0x1402000; the upstream machine gate skips
Uke. This candidate admits exactly xiaomi,uke + qcom,sm7675 with that version,
then uses the original upstream uefisecapp client and RTCInfo variable contract.
Unsupported secure callbacks fail instead of being accepted as normal results.
This is candidate platform admission, not an assertion of prior qualification.

The FDT helper admits the measured PMK RTC resources and adds only
`qcom,uefi-rtc-info`. It refuses direct-write and foreign NVMEM declarations.
It allocates no SDAM cell, changes no PMIC time register and writes no firmware
partition. Existing panel, touch recovery, MEMLAT, module-signing and root/slot
guards are retained from the published parent.

A missing RTCInfo variable registers an uninitialized RTC rather than exposing
a fabricated Unix calendar. Reads report ENODATA until an explicit trusted-time
write succeeds. A pre-2020 calendar is also uninitialized. Alarms cannot be
programmed or enabled while the calendar is uninitialized; alarm disabling is
retained. A successful write changes the existing twelve-byte RTCInfo record,
preserves its eight reserved bytes, reads it back under the same EFI variable
lock and admits the offset only on an exact match. An unchanged offset avoids
another write. Uke offset changes are persisted immediately; foreign-platform
deferred-write policy remains unchanged.

The paired boot-integration package provisions only NTP-synchronized UTC and
verifies RTC readback. After that initial calibration, the retained PMIC counter
and secure offset supply elapsed offline time on later boots. Initial calibration
still needs trusted UTC; a missing or unsupported firmware backend must remain
an explicit failure. The raw PMIC counter is intentionally preserved.

Native fixtures exercise the actual RTC callbacks, exact board/version admission,
uninitialized state, simulated restart, reserved bytes, unchanged writes, variable
failures and synthetic FDT refusals. The firmware application, real ioctl writes,
alarm delivery and cold power-cycle retention require independent device tests.
The candidate requires the paired RTC-capable installation profile/updater.

Source comparison: Xiaomi kernel5712080a4b0c and DT94c84aeb9e51; upstream
Linux v7.3.1 `drivers/rtc/rtc-pm8xxx.c`, `drivers/firmware/qcom/qcom_scm.c`,
`qcom_qseecom_uefisecapp.c` and `drivers/firmware/efi/vars.c`. GPL-2.0-only
driver changes retain their upstream attribution. Generic laptop SDAM offsets
were reviewed and are not Uke storage allocations.
