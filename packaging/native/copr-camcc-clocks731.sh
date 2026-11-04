#!/usr/bin/env bash
# COPR-only clock-callback integration qualification; no camera activation.
set -Eeuo pipefail
trap 'status=$?; printf "Source preparation failed at line %s (exit %s)\n" "$LINENO" "$status" >&2; exit "$status"' ERR
export LC_ALL=C
release=${UKE_CAMCC_BUILD_RELEASE:-1018}
[[ $release =~ ^[1-9][0-9]{3,4}$ && $release -ge 1018 ]]
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?COPR result directory}")
base_release=${UKE_CAMCC_PARENT_RELEASE:-1011}
case $base_release in
 1011)
  base_build=11246385
  base_header=1a5eea8444659804be066cd379c6021c067455cd9a6a9899c3857962a128a46a
  base_payload=914461682948289e960221fb64289e32ca6b6b2bf456357744afb90d591b6a42
  ;;
 1500)
  base_build=11251503
  base_commit_expected=3d8702b0116c4388d3977e8f566bcca900f2d3f6
  base_header=abea001cf467330fc360543023fcb8a9fa9726a08c53fd8e966c2683a3a51478
  base_payload=60f5a60e762725b9222dce4f6e61d5e1158adde6bf51c604ebed639946c87afc
  ;;
 1600)
  base_build=11251559
  base_commit_expected=31313e89f719b935bcd1301d48d807bd1dc27163
  base_header=f71eea4d521b2937c08d81886c9338e0908834491ee9bb35238a2b72171f58e5
  base_payload=b4f6340ccd8cd72fcfba6d462b869621eaf62793b28abc083bad53072838d5e7
  ;;
 1900)
  base_build=11252138
  base_commit_expected=aec8163b1ba0fba34e94f99accc99a18a46f8810
  base_header=1bb1e6fab32581f77f6babb69e2be7d405dfdf6a6d1513d515994d551e931f89
  base_payload=c91b0a390f73a7063bcb49221cf94d42ef2242b95e3a26f2d84b4428e7ca207f
  ;;
 3000)
  base_build=11252621
  base_commit_expected=b1e1979e16719c08b1eac1bbbbf4afc9c6facc21
  base_header=ef3834764344db7e8cab3f9eb26c55424a65c6e1dc32153ee6651c4af0fbfcae
  base_payload=c5956cf2b13628690d572197cc118612a67a6fc0394bc58c041d6f1cf31af69b
  ;;
 5000)
  base_build=11252769
  base_commit_expected=9d81bed196a7e1ae2018f24b611215b41fd3b75f
  base_header=db2abc55a679baefe85f055c2ffda7975ebd379b175dbecba0ab5934941d8d6a
  base_payload=8661dd73e069d451a1871f644272fbe5f9891c221608eb7d1d45b5aced72e6fa
  ;;
 *) printf 'Unqualified camera parent: %s\n' "$base_release" >&2; exit 1;;
esac
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
for project in uke-linux-unstable uke-linux-test uke-linux; do
 offset=0
 while ((offset < 10000)); do
  curl -fLsS --max-time 45 --get --data-urlencode ownername=mcc45tr \
   --data-urlencode "projectname=$project" --data-urlencode packagename=senemos-uke-linux-kernel-mainline \
   --data-urlencode limit=100 --data-urlencode "offset=$offset" \
   https://copr.fedorainfracloud.org/api_3/build/list > "$stage/builds.json"
  jq -e --arg release "$release" '(.items|type)=="array" and all(.items[];
    ((.source_package.version // "")|test("^7[.]3[.]1-"+$release+"([.]|$)"))|not)' "$stage/builds.json" >/dev/null
  count=$(jq -er '.items|length' "$stage/builds.json")
  ((count < 100)) && break
  offset=$((offset + 100))
 done
 ((offset < 10000))
done
[[ $(curl -fsSL --max-time 45 "https://copr.fedorainfracloud.org/api_3/build/$base_build" | jq -er .state) == succeeded ]]
curl -fLsS --retry 2 --proto '=https' --proto-redir '=https' \
 "https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/$base_build/senemos-uke-linux-kernel-mainline-7.3.1-$base_release.src.rpm" -o "$stage/base.src.rpm"
if [[ $base_release == 1011 ]]; then
 printf '%s  %s\n' 84915ef98a26df47bc8f223e3751b160e40eba3c447f433fbe13b2097d6a7146 "$stage/base.src.rpm" | sha256sum -c -
fi
[[ $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$stage/base.src.rpm") == senemos-uke-linux-kernel-mainline-7.3.1-$base_release ]]
# COPR's retained SRPM is unsigned. Pin its header and payload digest, then
# verify both over the complete remotely downloaded source RPM. This is not
# the signature policy for built binary packages or device installation.
[[ $(rpm -qp --qf '%{SHA256HEADER}' "$stage/base.src.rpm") == "$base_header" ]]
[[ $(rpm -qp --qf '%{PAYLOADSHA256}' "$stage/base.src.rpm") == "$base_payload" ]]
rpmkeys --checksig --nosignature --verbose "$stage/base.src.rpm"
parent_sha=$(sha256sum "$stage/base.src.rpm" | cut -d ' ' -f1)
printf 'Verified retained parent SRPM SHA256: %s\n' "$parent_sha"
rpm2cpio "$stage/base.src.rpm" > "$stage/base.cpio"
cpio -t --quiet < "$stage/base.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/base.cpio")
spec=$output/senemos-uke-linux-kernel-mainline.spec
if [[ $base_release == 1011 ]]; then
 printf '%s  %s\n' d48ae2fc7af05df331c15068e73eb77c4c50c203a57b7cdc6b1ff1e9509a334b "$spec" | sha256sum -c -
fi
archive=senemos-native-profile-7.3.1.tar.xz
find "$output" -maxdepth 1 -type f ! -name "${spec##*/}" ! -name "$archive" \
 -print0 | sort -z | xargs -0 sha256sum > "$stage/retained-sources.sha256"
tar -tJf "$output/$archive" > "$stage/archive.entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/archive.entries"
tar -xJf "$output/$archive" -C "$stage/unpacked"
profile=$stage/unpacked/native-profile
base_commit=$(cat "$profile/source-commit")
if [[ $base_release != 1011 ]]; then
 [[ $base_commit == "$base_commit_expected" ]]
 jq -e --arg release "$base_release" '.kernel_release==("7.3.1-"+$release) and .native_ssc_iio_abi==1 and
  .binder_ipc_builtin and .binderfs_builtin and .touch_recovery_attempts_per_powered_epoch==1 and
  .native_memlat_groups==["llcc","l3"] and
  .panel_variants==["o82_36_02_0a","o82_42_02_0b"] and .touch_variants==["tianma","csot"]' \
  "$profile/source-composition.json" >/dev/null
fi
if ((base_release >= 1600)); then
 jq -e '.rtc_backend=="qseecom-uefisecapp-RTCInfo" and .rtc_qseecom_version=="0x1402000" and
  .rtc_offset_write_readback and (.rtc_pmic_counter_writes|not) and (.rtc_sdam_writes|not)' \
  "$profile/source-composition.json" >/dev/null
fi
if [[ $base_release == 1900 || $base_release == 3000 || $base_release == 5000 ]]; then
 jq -e '.ssc_adsp_supplier_bound_gate==1 and .ssc_temperature_unit=="millicelsius" and
  .nfc_atomic_memory_read and .nfc_system_wakeup and .ir_explicit_word_bits==16 and
  .memlat_l3_capacity=="ERANGE-only-descending-OEM-map" and .memlat_strict_provider_unchanged and
  .o82_regdma_resource=={start:"0x0af80000",size:"0x7000"}' \
  "$profile/source-composition.json" >/dev/null
fi
if [[ $base_release == 3000 || $base_release == 5000 ]]; then
 jq -e '.qualified_ssc_large_report_check==11252237 and .ssc_report_type==1 and
  .ssc_indication_ids==[33,34] and .ssc_payload_limit==16384 and
  .wcd939x_telemetry_readonly==1 and .wcd939x_telemetry_getters_unchanged and
  .wcd939x_electrical_settings_unchanged and
  .ath11k_regulatory_status_diagnostics==1 and .ath11k_regulatory_policy_unchanged and
  .ath11k_regulatory_decisions_unchanged and .ath11k_wire_protocol_unchanged' \
  "$profile/source-composition.json" >/dev/null
fi
if [[ $base_release == 5000 ]]; then
 jq -e '.touch_gesture_setting_path=="OEM-mandatory-ACK-without-extra-getters" and
  .touch_gesture_setting_commands==[17,27] and (.touch_gesture_setting_getter_queries|not) and
  .touch_coordinate_readback_preserved and .touch_ack_retries==5 and
  .touch_mandatory_errors_preserved and .touch_panel_order_unchanged and
  .touch_firmware_calibration_unchanged and .touch_command_failure_diagnostics' \
  "$profile/source-composition.json" >/dev/null
 printf '%s  %s\n' f81f42c2622a6eb671fd7ca11fbb0ce700b6f5a7589a43cb379b5baa7cdfb1ca \
  "$profile/src/input/nt36532-uke-protocol.c" | sha256sum -c --strict
 for path in src/input/nt36532-uke-protocol.c tests/touch-gesture.c \
  tests/touch-protocol-contract.sh tests/fixtures/nt36532-before-gesture-ack.c \
  tests/touch-gesture-ack-regression.sh tests/touch-gesture-ack-package-contract.sh; do
  cmp "$profile/$path" "$owner/$path"
 done
fi
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS
 find . -type f ! -name SHA256SUMS ! -name source-commit ! -name source-composition.json \
  -print0 | sort -z | xargs -0 sha256sum > "$stage/retained-profile.sha256")
overlays=(src/camera/camcc-sm7675-data.h
 src/camera/include/dt-bindings/clock/qcom,sm7675-camcc.h
 src/camera/provider/0001-clk-qcom-gdsc-collapse-error.patch
 src/camera/provider/0002-clk-qcom-gdsc-controller-pm.patch
 src/camera/provider/0003-clk-qcom-gdsc-registration-unwind.patch
 src/camera/provider/camcc-sm7675-power.h src/camera/provider/camcc-sm7675-owner.h
 src/camera/provider/camcc-sm7675-clocks.h src/camera/provider/CLOCKS731.md
 src/camera/provider/OWNER731.md
 tests/camcc-power-contract.sh tests/camcc-provider-contract.sh tests/camcc-owner-object.sh
 tests/fixtures/camcc-power-check.c tests/fixtures/camcc-provider-check.c
 tests/fixtures/camcc-provider-object.c tests/fixtures/camcc-power-before-owner.h
 tests/fixtures/camcc-clocks-check.c)
for path in "${overlays[@]}"; do
 test ! -e "$profile/$path"
 install -Dm644 "$owner/$path" "$profile/$path"
done
cp "$profile/source-composition.json" "$profile/source-composition-before$release.json"
commit=$(git -C "$owner" rev-parse HEAD)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq --arg commit "$commit" --arg parent_sha "$parent_sha" --arg release "$release" \
 --arg base_release "$base_release" --arg base_commit "$base_commit" --argjson base_build "$base_build" \
 --arg base_header "$base_header" --arg base_payload "$base_payload" '. + {
 source_commit:$commit,source_mode:("retained"+$base_release+"-with-inactive-camcc-clock-callbacks"),
 camera_base_release:$base_release,camera_base_source_commit:$base_commit,camera_base_copr_build:$base_build,
 parent_copr_build:$base_build,parent_source_commit:$base_commit,parent_srpm_sha256:$parent_sha,
 parent_srpm_header_sha256:$base_header,parent_srpm_payload_sha256:$base_payload,
 parent_header_sha256:$base_header,parent_payload_sha256:$base_payload,
 parent_composition:("source-composition-before"+$release+".json"),kernel_release:("7.3.1-"+$release),rpm_revision:$release,
 changed_kernel_files:((.changed_kernel_files + ["drivers/clk/qcom/gdsc.c","drivers/clk/qcom/gdsc.h"])|unique),camera_dt_activation:false,
 controller_pm_domains_opted_in:0,camera_provider_registered:false,owner_object_installed:false,
 firmware_payload_included:false,automatic_policy_unchanged:true,physical_acceptance:false
 }' "$profile/source-composition-before$release.json" > "$profile/source-composition.json"
(cd "$profile"; sha256sum -c "$stage/retained-profile.sha256"
 find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner -cJf "$output/$archive" -C "$stage/unpacked" native-profile
for line in "%global senemos_build_release $base_release" 'bash native-profile/prepare.sh "$PWD"' 'uke_build_start=$SECONDS' '%check'; do
 [[ $(grep -Fxc "$line" "$spec") == 1 ]]
done
awk -v release="$release" -v parent="$base_release" '
 $0=="%global senemos_build_release " parent {$0="%global senemos_build_release " release}
 /^bash native-profile\/prepare.sh "\$PWD"$/ {
  print
  print "mkdir -p native-generated/camcc-baseline/drivers/clk/qcom"
  print "cp drivers/clk/qcom/gdsc.c drivers/clk/qcom/gdsc.h native-generated/camcc-baseline/drivers/clk/qcom/"
  print "for patch in native-profile/src/camera/provider/000[123]-clk-qcom-gdsc-*.patch; do git apply --check \"$patch\"; git apply \"$patch\"; done"
  print "test \"$(find native-profile/src/camera/provider -name '\''000[123]-clk-qcom-gdsc-*.patch'\'' | wc -l)\" = 3"
  print "if grep -l GDSC_CONTROLLER_PM drivers/clk/qcom/*-*.c; then exit 1; fi"
  next
 }
 /^uke_build_start=\$SECONDS$/ {
  print
  print "CC=clang bash native-profile/tests/camcc-power-contract.sh native-generated/camcc-baseline \"$PWD\""
  print "CC=clang CAMCC_TEST_FLAGS='\''-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer'\'' bash native-profile/tests/camcc-power-contract.sh native-generated/camcc-baseline \"$PWD\""
  print "CC=clang CAMCC_CLOCKS_TEST=1 bash native-profile/tests/camcc-provider-contract.sh \"$PWD\""
  print "CC=clang CAMCC_CLOCKS_TEST=1 CAMCC_TEST_FLAGS='\''-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer'\'' bash native-profile/tests/camcc-provider-contract.sh \"$PWD\""
  next
 }
 /^%check$/ {
  print
  print "grep -Fx CONFIG_QCOM_GDSC=y %{_uke_out}/.config"
  print "test -s %{_uke_out}/drivers/clk/qcom/gdsc.o"
  print "llvm-readelf -h %{_uke_out}/drivers/clk/qcom/gdsc.o | grep -E '\''Machine:.*AArch64'\''"
  print "bash native-profile/tests/camcc-owner-object.sh \"$PWD\" %{_uke_out} %{buildroot}"
  next
 }
 /^%changelog$/ {
  print; print "* Tue Nov 03 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-" release
  print "- Qualify CAMCC per-clock voltage callbacks and retained fault state."
  print "- Compile GDSC controller-PM support without opting in any domain or activating camera DT."
  print ""; next
 }
 {print}
' "$spec" > "$stage/next.spec"
mv "$stage/next.spec" "$spec"
sha256sum -c "$stage/retained-sources.sha256"
[[ $(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec") == 7.3.1-$release ]]
