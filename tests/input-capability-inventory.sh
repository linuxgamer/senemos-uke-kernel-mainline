#!/usr/bin/env bash
# Synthetic regular files only; never inspect a host input device.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir "$fixture/empty"
run() { bash "$repo/scripts/input-capability-inventory.sh" --sysfs-input "$fixture/input"; }
reject() {
    if run > "$fixture/result.json" 2> "$fixture/error"; then echo 'Invalid input metadata accepted' >&2; exit 1; fi
    [[ ! -s $fixture/result.json ]]
}
bash "$repo/scripts/input-capability-inventory.sh" --sysfs-input "$fixture/empty" > "$fixture/empty.json"
jq -e '.input_nodes==[] and .physical_capabilities_verified==false' "$fixture/empty.json" >/dev/null
# Permission denial is exercised by non-root runners. Root can bypass mode
# bits, so the injected enumeration failures below are mandatory for everyone.
mkdir "$fixture/denied"
chmod 000 "$fixture/denied"
if [[ ! -r $fixture/denied || ! -x $fixture/denied ]]; then
 if bash "$repo/scripts/input-capability-inventory.sh" --sysfs-input "$fixture/denied" > "$fixture/denied.json" 2>/dev/null; then
  chmod 700 "$fixture/denied"; exit 1
 fi
 [[ ! -s $fixture/denied.json ]]
fi
chmod 700 "$fixture/denied"
mkdir "$fixture/bin"
cat > "$fixture/bin/find" <<'SH'
#!/usr/bin/env bash
# Simulate inaccessible enumeration and interrupted traversal after one entry.
[[ ${INVENTORY_PARTIAL:-0} != 1 ]] || printf 'event0\n'
exit 1
SH
chmod +x "$fixture/bin/find"
for partial in 0 1; do
 if PATH="$fixture/bin:$PATH" INVENTORY_PARTIAL=$partial bash "$repo/scripts/input-capability-inventory.sh" --sysfs-input "$fixture/empty" > "$fixture/denied.json" 2>/dev/null; then exit 1; fi
 [[ ! -s $fixture/denied.json ]]
done
mkdir -p "$fixture/input/event0/device/"{id,capabilities}
for key in bustype vendor product version; do printf '0001\n' > "$fixture/input/event0/device/id/$key"; done
for key in ev key rel abs msc led snd ff sw; do printf '0\n' > "$fixture/input/event0/device/capabilities/$key"; done
printf '8000000000000000 0 1\n' > "$fixture/input/event0/device/capabilities/abs"
# Typical sysfs class entry is a symlink. Also include unqualified private data
# and a non-event entry: none may appear in the public inventory.
mv "$fixture/input/event0" "$fixture/device"
ln -s "$fixture/device" "$fixture/input/event0"
printf 'PRIVATE-SENTINEL\n' > "$fixture/device/device/uniq"
printf 'PRIVATE-SENTINEL\n' > "$fixture/device/device/name"
mkdir "$fixture/input/event-invalid"
run > "$fixture/result.json"
jq -e '.snapshot_atomic==false and .device_nodes_opened==false and .physical_capabilities_verified==false and (.input_nodes|length)==1 and .input_nodes[0].node=="event0" and .input_nodes[0].capability_hex_words.abs=="8000000000000000 0 1" and (.input_nodes[0]|keys)==["capability_hex_words","node","type_ids"] and (.input_nodes[0].type_ids|keys)==["bustype","product","vendor","version"]' "$fixture/result.json" >/dev/null
if grep -Fq PRIVATE-SENTINEL "$fixture/result.json"; then exit 1; fi
cp "$fixture/device/device/capabilities/abs" "$fixture/abs"
for value in invalid '0;command' '0  1' $'0\n1'; do
 printf '%s\n' "$value" > "$fixture/device/device/capabilities/abs"; reject
done
printf '%04100d\n' 0 > "$fixture/device/device/capabilities/abs"; reject
printf '0\n%.0s' {1..2100} > "$fixture/device/device/capabilities/abs"; reject
cp "$fixture/abs" "$fixture/device/device/capabilities/abs"
printf '00010002\n' > "$fixture/device/device/id/vendor"; reject
printf '0001\n' > "$fixture/device/device/id/vendor"
rm "$fixture/device/device/capabilities/abs"; reject
mkfifo "$fixture/device/device/capabilities/abs"; reject
rm "$fixture/device/device/capabilities/abs"
cp "$fixture/abs" "$fixture/device/device/capabilities/abs"
# A second incomplete node must refuse the whole report, not emit partial data.
mkdir -p "$fixture/input/event1/device"
reject
printf 'Input inventory: checked root enumeration, empty/symlinked metadata, opaque bitmap preservation, private field exclusion, malformed/oversized/missing/FIFO and incomplete-node refusal passed; no device opened\n'
