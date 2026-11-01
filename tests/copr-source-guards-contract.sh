#!/usr/bin/env bash
# Bash/native RPM metadata only; no network, compiler or target workload.
set -Eeuo pipefail
owner=$(cd -- "$(dirname -- "$0")/.." && pwd)
recipes=${1:-$owner/packaging/native}
release_guard=${2:-$owner/packaging/native/refuse-published-release.sh}
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
for recipe in copr-framebuffer55 copr-reservation56 copr-lifecycle57 copr-retirement58 copr-transaction59 copr-regression60 copr-transaction73 copr-stable731 copr-o82-avr731 copr-o82-abm731;do
 path_check=$(awk '/awk .*bad/ && index($0,"\"$stage/entries\"") {print;found++} END {if(found!=1)exit 1}' "$recipes/$recipe.sh")
 printf 'set -Eeuo pipefail\nstage=${1:?}\n%s\nprintf reached\n' "$path_check" > "$work/entry-check.sh"
 for path in './safe/file' 'safe/../escape' '/absolute' '../escape' './safe/../../escape' './safe/.../file';do
  printf '%s\n' "$path" > "$work/entries"
  set +e
  bash "$work/entry-check.sh" "$work" > "$work/result"
  status=$?
  set -e
  case $path in
   './safe/file'|'./safe/.../file') [[ $status == 0 && $(cat "$work/result") == reached ]];;
   *) [[ $status != 0 && ! -s $work/result ]];;
  esac
 done
done
mkdir "$work/bin"
cat > "$work/bin/curl" <<'SH'
#!/usr/bin/env bash
if [[ -n ${UKE_GUARD_TEST_RESPONSE:-} && " $* " == *' projectname=uke-linux-test '* ]]; then
 cat "$UKE_GUARD_TEST_RESPONSE"
else
 cat "$UKE_GUARD_RESPONSE"
fi
SH
chmod 755 "$work/bin/curl"
export UKE_GUARD_RESPONSE=$work/builds.json
name=senemos-uke-linux-kernel-mainline
for state in succeeded running failed canceled;do
 jq -n --arg name "$name" --arg state "$state" \
  '{items:[{state:$state,source_package:{name:$name,version:"7.3.0-58",url:"https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/1/kernel.src.rpm"}}]}' > "$work/builds.json"
 for proposed in 7.3.0-57 7.3.0-58 7.3.0-59;do
  set +e
  PATH="$work/bin:$PATH" bash "$release_guard" "$name" "$proposed" > "$work/result" 2>&1
  status=$?
  set -e
  if [[ $proposed == 7.3.0-59 ]];then [[ $status == 0 ]];else [[ $status != 0 ]];fi
 done
done
# An unsourced failed attempt consumes no release. Malformed published metadata refuses.
for kind in unsourced malformed missing_url;do
 case $kind in
  unsourced) printf '{"items":[{"state":"failed","source_package":{"name":null,"version":null,"url":null}}]}' > "$work/builds.json";;
  malformed) jq -n --arg name "$name" '{items:[{state:"succeeded",source_package:{name:$name,version:"58;foreign",url:null}}]}' > "$work/builds.json";;
  missing_url) jq -n --arg name "$name" '{items:[{state:"succeeded",source_package:{name:$name,version:"7.3.0-58",url:null}}]}' > "$work/builds.json";;
 esac
 set +e
 PATH="$work/bin:$PATH" bash "$release_guard" "$name" 7.3.0-58 > "$work/result" 2>&1
 status=$?
 set -e
 if [[ $kind == unsourced ]];then [[ $status == 0 ]];else [[ $status != 0 ]];fi
done
# A version consumed in either project must refuse even if the other is empty.
export UKE_GUARD_TEST_RESPONSE=$work/test-builds.json
for consuming_project in unstable test; do
 printf '{"items":[]}' > "$work/builds.json"
 printf '{"items":[]}' > "$work/test-builds.json"
 if [[ $consuming_project == test ]]; then destination=$work/test-builds.json; else destination=$work/builds.json; fi
 jq -n --arg name "$name" '{items:[{state:"running",source_package:{name:$name,version:"7.3.1-14",url:"https://example.invalid/kernel.src.rpm"}}]}' > "$destination"
 for proposed in 7.3.1-14 7.3.1-15; do
  set +e
  PATH="$work/bin:$PATH" bash "$release_guard" "$name" "$proposed" > "$work/result" 2>&1
  status=$?
  set -e
  if [[ $proposed == 7.3.1-15 ]]; then [[ $status == 0 ]]; else [[ $status != 0 ]]; fi
 done
done
printf 'Actual source-worker path refusals and consumed-source NVR guards pass; no compilation or network\n'
