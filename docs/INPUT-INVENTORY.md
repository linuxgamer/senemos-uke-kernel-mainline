# Input capability inventory

30 October 2026. The Bash helper reads existing Linux sysfs input metadata:

```sh
bash scripts/input-capability-inventory.sh --sysfs-input /sys/class/input
```

It requires Bash, jq, GNU find and head. It does not open event/hidraw nodes, record
keystrokes, grab devices, rebind drivers, load firmware or write settings.
No elevated privilege is requested. An inaccessible, malformed or disappearing
node refuses the report; the tool emits JSON only after all enumerated nodes
pass. Root read/search access and enumeration completion are checked explicitly;
failed or partial enumeration cannot become an empty successful inventory.
An empty inventory is possible and is not a capability result.

Output includes event-node labels, shared bus/vendor/product/version IDs and
opaque hexadecimal capability words. It excludes names, physical paths, unique
IDs and uevents. Event numbers are transient; compare capability/type tuples,
not event numbers, across boots. The snapshot is not atomic and can miss a
concurrent attachment. A successful inventory does not prove that events arrive
or that a particular pen, keyboard, touchpad or button works. Bitmap decoding
requires the producing kernel's word size and Linux input ABI.

For Xiaomi Focus Pen/Keyboard investigation, first record the current OS/kernel
and actual accessory model separately, then compare a deliberately coordinated
attached/detached inventory. Report descriptors and consented event samples are
separate future evidence; do not infer pressure or hover from a device label.
Retain raw data privately and review any additional data before publication.

`bash tests/input-capability-inventory.sh` tests synthetic metadata, symlinks,
private-field exclusion and malformed/missing/oversized/incomplete input. No
host or tablet input node is opened by that fixture.
