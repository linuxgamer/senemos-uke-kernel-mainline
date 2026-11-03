#!/usr/bin/env bash
# COPR source-worker guard: a new module-signing key requires a fresh kernel NVR.
set -Eeuo pipefail
name=${1:?Pass the source package name}
candidate=${2:?Pass the proposed version-release without the Fedora suffix}
[[ $name =~ ^[a-zA-Z0-9+_.-]+$ && $candidate =~ ^[0-9]+([.][0-9]+)*-[1-9][0-9]*$ ]]
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
for project in uke-linux uke-linux-test uke-linux-unstable; do
 offset=0
 while ((offset < 10000)); do
    curl --fail --silent --show-error --location --max-time 45 --get \
        --data-urlencode ownername=mcc45tr --data-urlencode "projectname=$project" \
        --data-urlencode "packagename=$name" --data-urlencode limit=100 --data-urlencode "offset=$offset" \
        https://copr.fedorainfracloud.org/api_3/build/list > "$work/builds.json"
    jq -e '(.items|type)=="array"' "$work/builds.json" > /dev/null
    mapfile -t versions < <(jq -r --arg name "$name" \
        '.items[]|select(.source_package.name==$name and
          (.state=="succeeded" or (.source_package.url | type=="string" and length>0)))|
          .source_package.version' "$work/builds.json")
    for published in "${versions[@]}"; do
        # Whitelist the complete value before passing it to rpm's Lua evaluator.
        [[ $published =~ ^[0-9]+([.][0-9]+)*-[0-9]+([.][a-zA-Z0-9]+)*$ ]] || {
            echo 'Unrecognized published kernel version; review before rebuilding' >&2; exit 1;
        }
        comparison=$(rpm --eval "%{lua:print(rpm.vercmp(\"$published\", \"$candidate\"))}")
        [[ $comparison =~ ^-?[0-9]+$ ]]
        if ((comparison >= 0)); then
            printf 'Refusing %s: %s published %s is equal or newer; use a fresh kernel release\n' "$candidate" "$project" "$published" >&2
            exit 1
        fi
    done
    count=$(jq -er '.items|length' "$work/builds.json")
    if ((count < 100)); then
        break
    fi
    offset=$((offset + 100))
 done
 ((offset < 10000)) || {
  echo 'Build history limit reached; review before rebuilding' >&2
  exit 1
 }
done
printf 'Fresh kernel release admitted across all COPR projects: %s\n' "$candidate"
