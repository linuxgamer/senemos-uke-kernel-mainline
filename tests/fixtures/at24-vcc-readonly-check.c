/* SPDX-License-Identifier: GPL-2.0-only */
/* Actual before/after read and PM bodies; synthetic bytes and fake OS rails. */
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
typedef uint32_t u32;
#define __maybe_unused
#define unlikely(x) (x)
#define READ_ONCE(x) (x)
#define WRITE_ONCE(x, value) ((x) = (value))
#define AT24_FLAG_READONLY 0x40U
#define dev_err(...) do { } while (0)
struct mutex { pthread_mutex_t handle; };
static void mutex_init(struct mutex *m) { assert(!pthread_mutex_init(&m->handle, NULL)); }
static void mutex_lock(struct mutex *m) { assert(!pthread_mutex_lock(&m->handle)); }
static void mutex_unlock(struct mutex *m) { assert(!pthread_mutex_unlock(&m->handle)); }
struct at24_data;
struct device { struct at24_data *data; };
struct i2c_client { struct device dev; struct at24_data *data; };
struct regulator { int unused; };
struct at24_data {
 struct mutex lock, vcc_lock;
 u32 byte_len, vcc_uV;
 int vcc_fault;
 bool vcc_voltage_held, vcc_io_active;
 struct regulator *vcc_reg;
 void (*read_post)(unsigned int, char *, size_t);
 struct i2c_client client;
};
static struct at24_data chip;
static struct regulator rail;
static bool voltage_property, supply_property, baseline_control, strict_voltage;
static u32 requested_voltage;
static int property_error, voltage, peer_voltage, enable_error, vote_error, release_error;
static int disable_error, read_error, busy_suspend;
static unsigned enabled, refs, votes, releases, enables, disables, reads, posts;
static bool suspended, idle_immediate;
enum event { VOTE, ENABLE, READ, POST, DISABLE, RELEASE };
static enum event trace[4096];
static unsigned traces;
static void event(enum event e) { assert(traces < sizeof(trace)/sizeof(trace[0])); trace[traces++] = e; }
static struct device *at24_base_client_dev(struct at24_data *c) { return &c->client.dev; }
static struct i2c_client *to_i2c_client(struct device *d) { return &d->data->client; }
static struct at24_data *i2c_get_clientdata(struct i2c_client *c) { return c->data; }
static bool device_property_present(struct device *d, const char *name)
{
 assert(d == &chip.client.dev);
 if (!strcmp(name, "vcc-microvolt")) return voltage_property;
 assert(!strcmp(name, "vcc-supply")); return supply_property;
}
static int device_property_read_u32(struct device *d, const char *name, u32 *value)
{
 assert(d == &chip.client.dev && !strcmp(name, "vcc-microvolt"));
 if (property_error) return property_error;
 *value = requested_voltage; return 0;
}
static int regulator_set_voltage(struct regulator *r, int low, int high)
{
 assert(r == &rail);
 if (low) {
  assert(low == 1800000 && high == low); votes++; event(VOTE);
  if (vote_error) return vote_error;
  if (peer_voltage && peer_voltage != low) return -EINVAL;
  voltage = low;
 } else {
  assert(high == INT_MAX && !enabled);
  releases++; event(RELEASE);
  if (release_error) return release_error;
  voltage = peer_voltage ? peer_voltage : 1620000;
 }
 return 0;
}
static int regulator_enable(struct regulator *r)
{
 assert(r == &rail && !enabled); enables++; event(ENABLE);
 if (strict_voltage && !baseline_control) assert(voltage == 1800000);
 if (enable_error) return enable_error;
 enabled = 1; return 0;
}
static int regulator_disable(struct regulator *r)
{
 assert(r == &rail && enabled); disables++; event(DISABLE);
 if (disable_error) return disable_error;
 enabled = 0; return 0;
}
static int pm_runtime_resume_and_get(struct device *);
static void pm_runtime_put(struct device *);
static int pm_runtime_suspend(struct device *);
static bool pm_runtime_status_suspended(struct device *);
static int at24_regmap_read(struct at24_data *c, char *buf, unsigned off, size_t count)
{
 assert(c == &chip && enabled && !suspended && refs);
 if (strict_voltage && voltage != 1800000) {
  if (baseline_control)
   fputs("Original at24 reaches EEPROM read at the unrequested 1620000uV level\n", stderr);
  assert(voltage == 1800000);
 }
 assert(off < c->byte_len && count <= c->byte_len - off);
 reads++; event(READ);
 if (read_error) return read_error;
 size_t bytes = count > 128 ? 128 : count;
 memset(buf, 0xa5, bytes);
 if (strict_voltage && !baseline_control) usleep(100);
 return (int)bytes;
}
#define at24_read before_read
#include "before-read.h"
#undef at24_read
#include "after-read-data.h"
#include "at24-vcc-readonly.h"
#define at24_suspend before_suspend
#include "before-suspend.h"
#undef at24_suspend
#define at24_resume before_resume
#include "before-resume.h"
#undef at24_resume
#include "after-suspend.h"
#include "after-resume.h"
static int pm_runtime_resume_and_get(struct device *dev)
{
 assert(dev == &chip.client.dev);
 if (suspended) {
  int ret = baseline_control ? before_resume(dev) : at24_resume(dev);
  if (ret) return ret;
  suspended = false;
 }
 refs++; return 0;
}
static void pm_runtime_put(struct device *dev)
{
 assert(dev == &chip.client.dev && refs); refs--;
 if (idle_immediate && !refs) (void)pm_runtime_suspend(dev);
}
static int pm_runtime_suspend(struct device *dev)
{
 assert(dev == &chip.client.dev);
 if (suspended) return 1;
 if (refs || busy_suspend) return -EBUSY;
 int ret = baseline_control ? before_suspend(dev) : at24_suspend(dev);
 if (!ret) suspended = true;
 return ret;
}
static bool pm_runtime_status_suspended(struct device *dev)
{ assert(dev == &chip.client.dev); return suspended; }
static void post(unsigned off, char *buf, size_t count)
{ assert(off == 7 && count == 257 && buf[0] == (char)0xa5); posts++; event(POST); }
static void reset(void)
{
 static bool initialized;
 if (initialized) {
  assert(!pthread_mutex_destroy(&chip.lock.handle));
  assert(!pthread_mutex_destroy(&chip.vcc_lock.handle));
 }
 memset(&chip, 0, sizeof(chip)); initialized = true;
 mutex_init(&chip.lock); mutex_init(&chip.vcc_lock);
 chip.byte_len = 8192; chip.vcc_uV = 1800000; chip.vcc_reg = &rail;
 chip.client.data = chip.client.dev.data = &chip;
 voltage_property = supply_property = strict_voltage = true;
 baseline_control = idle_immediate = false;
 requested_voltage = 1800000; property_error = 0;
 voltage = 1620000;
 peer_voltage = 0;
 enable_error = vote_error = release_error = disable_error = read_error = busy_suspend = 0;
 enabled = refs = votes = releases = enables = disables = reads = posts = traces = 0;
 suspended = true;
}
static void closed(void)
{
 assert(!enabled && !refs && suspended && !chip.vcc_voltage_held && !chip.vcc_fault);
 assert(voltage == 1620000 && !chip.vcc_io_active);
}
static void *thread_read(void *argument)
{
 (void)argument;
 char buf[257];
 for (unsigned i = 0; i < 3; i++) assert(!at24_read(&chip, 7, buf, sizeof(buf)));
 return NULL;
}
int main(int argc, char **argv)
{
 char buf[8192];
 reset();
 if (argc == 2 && !strcmp(argv[1], "before")) {
  baseline_control = true; chip.vcc_uV = 0;
  (void)before_read(&chip, 0, buf, 1);
  assert(!"Original voltage admission failure must be detected");
 }
 assert(argc == 1);
 for (unsigned immediate = 0; immediate < 2; immediate++) {
  reset(); idle_immediate = immediate; chip.read_post = post;
  assert(!at24_read(&chip, 7, buf, 257)); closed();
  assert(votes == 1 && enables == 1 && reads == 3 && posts == 1 && disables == 1 && releases == 1);
  const enum event expected[] = {VOTE, ENABLE, READ, READ, READ, POST, DISABLE, RELEASE};
  assert(traces == sizeof(expected)/sizeof(expected[0]) && !memcmp(trace, expected, sizeof(expected)));
 }
 reset(); assert(!at24_read(&chip, 0, buf, sizeof(buf))); closed(); assert(reads == 64);
 reset(); voltage = peer_voltage = 1800000;
 assert(!at24_read(&chip, 0, buf, 1));
 assert(!enabled && !refs && suspended && !chip.vcc_voltage_held && !chip.vcc_fault);
 assert(voltage == 1800000 && peer_voltage == 1800000 && releases == 1);
 reset(); peer_voltage = 1620000;
 assert(at24_read(&chip, 0, buf, 1) == -EINVAL && !enables && !reads);
 closed(); assert(peer_voltage == 1620000);
 reset();
 const struct { unsigned off; size_t count; void *buffer; int result; } ranges[] = {
  {0, 0, NULL, 0}, {UINT_MAX, 0, NULL, 0}, {8192, 1, buf, -EINVAL},
  {UINT_MAX, 1, buf, -EINVAL}, {1, SIZE_MAX, buf, -EINVAL}, {0, 1, NULL, -EINVAL},
 };
 for (unsigned i = 0; i < sizeof(ranges)/sizeof(ranges[0]); i++)
  assert(at24_read(&chip, ranges[i].off, ranges[i].buffer, ranges[i].count) == ranges[i].result);
 assert(!votes && !enables && !reads && !disables && !releases); closed();
 reset(); chip.vcc_uV = 0; voltage_property = false;
 assert(!at24_vcc_configure(&chip.client.dev, &chip, 0) && !chip.vcc_uV);
 voltage_property = true; assert(at24_vcc_configure(&chip.client.dev, &chip, 0) == -EINVAL);
 supply_property = false; assert(at24_vcc_configure(&chip.client.dev, &chip, AT24_FLAG_READONLY) == -EINVAL);
 supply_property = true; property_error = -EIO;
 assert(at24_vcc_configure(&chip.client.dev, &chip, AT24_FLAG_READONLY) == -EIO);
 property_error = 0; requested_voltage = 0;
 assert(at24_vcc_configure(&chip.client.dev, &chip, AT24_FLAG_READONLY) == -EINVAL);
 requested_voltage = UINT_MAX;
 assert(at24_vcc_configure(&chip.client.dev, &chip, AT24_FLAG_READONLY) == -EINVAL);
 requested_voltage = 1800000;
 assert(!at24_vcc_configure(&chip.client.dev, &chip, AT24_FLAG_READONLY) && chip.vcc_uV == 1800000);
 reset(); vote_error = -ERANGE;
 assert(at24_read(&chip, 0, buf, 1) == -ERANGE && votes == 1 && !enables && !reads); closed();
 reset(); enable_error = -EIO;
 assert(at24_read(&chip, 0, buf, 1) == -EIO && votes == 1 && enables == 1 && !reads && releases == 1); closed();
 reset(); enable_error = -EIO; release_error = -EREMOTEIO;
 assert(at24_read(&chip, 0, buf, 1) == -EIO && chip.vcc_fault == -EREMOTEIO);
 unsigned events = traces;
 assert(at24_read(&chip, 0, buf, 1) == -EREMOTEIO && traces == events && !enabled && !reads && chip.vcc_voltage_held);
 reset(); read_error = -ENXIO;
 assert(at24_read(&chip, 0, buf, 1) == -ENXIO); closed();
 reset(); disable_error = -EIO;
 assert(at24_read(&chip, 0, buf, 1) == -EIO && chip.vcc_fault == -EIO && enabled && chip.vcc_voltage_held && !releases);
 events = traces; assert(at24_read(&chip, 0, buf, 1) == -EIO && traces == events);
 reset(); release_error = -EREMOTEIO;
 assert(at24_read(&chip, 0, buf, 1) == -EREMOTEIO && suspended && !enabled && chip.vcc_voltage_held);
 events = traces; assert(at24_read(&chip, 0, buf, 1) == -EREMOTEIO && traces == events);
 reset(); read_error = -ENXIO; disable_error = -EIO;
 assert(at24_read(&chip, 0, buf, 1) == -ENXIO && chip.vcc_fault == -EIO && chip.vcc_voltage_held);
 reset(); busy_suspend = 1;
 assert(at24_read(&chip, 0, buf, 1) == -EBUSY && enabled && !chip.vcc_fault && !releases);
 busy_suspend = 0; assert(!pm_runtime_suspend(&chip.client.dev)); closed();
 reset(); enabled = 1; suspended = false;
 assert(at24_read(&chip, 0, buf, 1) == -EHOSTDOWN && !reads && !votes);
 closed();
 reset(); assert(!at24_resume(&chip.client.dev)); suspended = false; refs = 1;
 assert(at24_read(&chip, 0, buf, 1) == -EBUSY && refs == 1 && enabled && !releases);
 refs = 0; assert(!pm_runtime_suspend(&chip.client.dev)); closed();
 reset(); chip.vcc_io_active = true;
 assert(at24_suspend(&chip.client.dev) == -EBUSY && !votes && !disables && !releases);
 reset(); strict_voltage = false; chip.vcc_uV = 0;
 assert(!at24_read(&chip, 0, buf, 1) && enabled && !votes && !releases);
 assert(!pm_runtime_suspend(&chip.client.dev)); closed();
 reset();
 pthread_t threads[4];
 for (unsigned i = 0; i < 4; i++) assert(!pthread_create(&threads[i], NULL, thread_read, NULL));
 for (unsigned i = 0; i < 4; i++) assert(!pthread_join(threads[i], NULL));
 closed(); assert(votes == 12 && enables == 12 && disables == 12 && releases == 12 && reads == 36);
 puts("Actual at24 read/PM: original unvoted read, voltage-before-enable, serialized reads, owned disable before withdrawal, modeled shared-rail peer, legacy path, bounds/config refusals, PM/I2C/rail faults and sticky containment pass; synthetic bytes only");
 assert(!pthread_mutex_destroy(&chip.lock.handle));
 assert(!pthread_mutex_destroy(&chip.vcc_lock.handle));
 return 0;
}
