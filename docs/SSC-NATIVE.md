# Native SSC consumer work

3 November 2026. The firmware-owned sensor description in DT does not create
working IIO devices. The ADSP retains the sensor buses; no duplicate AP I2C
clients or direct register accesses are added.

`src/sensors/uke-ssc-protocol.c` adds a bounded C decoder for the future native
consumer. It validates SUID identity, event framing, required fields, duplicate
fields, vector dimensions, sample status and finite IEEE754 wire values.
Discovery retains empty results and refuses duplicate SUIDs. Event payloads
borrow immutable input storage. Integer conversion rejects overflow without
kernel floating point. Failed decoding leaves the output unchanged.

Protocol sources are the pinned
[Qualcomm client API](https://github.com/qualcomm/sensinghub/blob/329551963bcc063f6a89f6cbca259c5b5c9c4e0b/apis/proto/sns_client.proto),
standard sensor/SUID schemas at the same commit, and the project's existing
MIT SSC discovery/sample code. Upstream Linux7.3.1 QMI helper declarations
were compared separately. The older SMGR service is a different protocol;
its IIO driver cannot be selected as an SSC service400 implementation.

The remote check producer is `packaging/native/copr-ssc-protocol-check.sh`.
It exercises synthetic valid/malformed packets with GCC and Clang sanitizers
and compares integer scaling with independent host floating-point arithmetic.
Remote validation is pending. No compile is run on the tablet.

This source does not yet register a QRTR/QMI client, request samples, create
IIO devices or replace libssc. Transport acknowledgement/client ownership,
metadata admission, service restart, buffer lifetime and suspend teardown
remain required integration work. Sample bits and sensor timestamps are not
assigned physical units or a clock rate by this decoder. Vendor CCT/flicker
semantics and physical accessory/sensor tests remain separate.
