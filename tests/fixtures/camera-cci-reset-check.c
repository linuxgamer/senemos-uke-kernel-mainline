/* SPDX-License-Identifier: GPL-2.0-only */
/* Actual stable/patched probe and unchanged reset/ISR; fake OS/MMIO only. */
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef int irqreturn_t;
#define BIT(n) (1U << (n))
#define msecs_to_jiffies(n) (n)
#define unlikely(x) (x)
#define IRQ_NONE 0
#define IRQ_HANDLED 1
#define GFP_KERNEL 0
#define MSEC_PER_SEC 1000
#define I2C_MODE_STANDARD 0
#define I2C_MODE_FAST 1
#define I2C_MODE_FAST_PLUS 2
#define I2C_MAX_FAST_MODE_FREQ 400000
#define I2C_MAX_FAST_MODE_PLUS_FREQ 1000000
#define dev_err(...) do { } while (0)
#define dev_dbg(...) do { } while (0)
#define dev_err_probe(dev, error, ...) (error)
#define IS_ERR(p) ((intptr_t)(p) < 0)
#define PTR_ERR(p) ((int)(intptr_t)(p))
#include "cci-registers.h"
struct device_node { unsigned idx; struct device_node *next; };
struct device { struct device_node *of_node; struct device *parent; };
struct platform_device { struct device dev; void *data; };
struct resource { int unused; };
struct completion { bool initialized; unsigned done; };
struct i2c_adapter {
 const void *quirks, *algo;
 struct device dev;
 char name[48];
};
struct cci;
struct cci_master {
 struct i2c_adapter adap;
 u16 master;
 u8 mode;
 int status;
 struct completion irq_complete;
 struct cci *cci;
};
struct cci_data { unsigned num_masters; int quirks; };
struct cci {
 struct device *dev;
 void *base;
 unsigned irq;
 const struct cci_data *data;
 int nclocks;
 void *clocks;
 struct cci_master master[2];
};
static const int cci_algo;
static struct cci_data profile = {2, 0};
static struct cci *allocated;
static unsigned char mmio[0xc10];
static unsigned initialized, writes, added, deleted, resets, clock_on, init_calls;
static unsigned fail_irq, timeout_reset, fail_pm, fail_adapter;
static bool missing_match, baseline_control;
static irqreturn_t cci_isr(int irq, void *data);
static void init_completion(struct completion *c)
{ assert(!c->initialized); c->initialized = true; initialized++; }
static void reinit_completion(struct completion *c) { c->done = 0; }
static void complete(struct completion *c)
{
 if (baseline_control && !c->initialized)
  fputs("Original master-1-only probe reaches an uninitialized completion\n", stderr);
 assert(c->initialized);
 c->done++;
}
static unsigned wait_for_completion_timeout(struct completion *c, unsigned timeout)
{ assert(c->initialized && timeout == CCI_TIMEOUT); return c->done; }
static u32 readl(const void *p)
{
 u32 value;
 assert(clock_on && (const unsigned char *)p >= mmio &&
        (const unsigned char *)p + 4 <= mmio + sizeof(mmio));
 memcpy(&value, p, 4);
 return value;
}
static void writel(u32 value, void *p)
{
 assert(clock_on && (unsigned char *)p >= mmio &&
        (unsigned char *)p + 4 <= mmio + sizeof(mmio));
 writes++;
 memcpy(p, &value, 4);
 if (p == mmio + CCI_RESET_CMD) {
  assert(value == CCI_RESET_CMD_MASK);
  resets++;
  if (!timeout_reset) {
   value = CCI_IRQ_STATUS_0_RST_DONE_ACK;
   memcpy(mmio + CCI_IRQ_STATUS_0, &value, 4);
   assert(cci_isr(42, allocated) == IRQ_HANDLED);
  }
 }
}
static void *devm_kzalloc(struct device *dev, size_t size, unsigned flags)
{ assert(!allocated && size == sizeof(*allocated)); return allocated = calloc(1, size); }
static void platform_set_drvdata(struct platform_device *p, void *data) { p->data = data; }
static const struct cci_data *device_get_match_data(struct device *dev)
{ return missing_match ? NULL : &profile; }
#define for_each_available_child_of_node_scoped(node, child) \
 for (struct device_node *child = (node); child; child = child->next)
static int of_property_read_u32(struct device_node *node, const char *name, u32 *value)
{
 if (!strcmp(name, "reg")) { *value = node->idx; return 0; }
 assert(!strcmp(name, "clock-frequency")); *value = 400000; return 0;
}
static struct device_node *of_node_get(struct device_node *node) { return node; }
static void cci_put_of_node(void *data) { assert(data); }
static int devm_add_action_or_reset(struct device *d, void (*fn)(void *), void *data)
{ assert(fn == cci_put_of_node && data); return 0; }
static void i2c_set_adapdata(struct i2c_adapter *a, struct cci_master *m)
{ assert(a == &m->adap); }
static void *devm_platform_get_and_ioremap_resource(struct platform_device *p, int index, struct resource **r)
{ assert(index == 0); return mmio; }
static int devm_clk_bulk_get_all(struct device *d, void **clocks)
{ *clocks = &profile; return 2; }
static int cci_enable_clocks(struct cci *c) { assert(c == allocated && !clock_on); clock_on = 1; return 0; }
static void cci_disable_clocks(struct cci *c) { assert(c == allocated && clock_on); clock_on = 0; }
static int platform_get_irq(struct platform_device *p, int index) { assert(!index); return 42; }
static const char *dev_name(struct device *d) { return "fixture-cci"; }
static int devm_request_irq(struct device *d, unsigned irq, irqreturn_t (*fn)(int, void *),
                            unsigned flags, const char *name, void *data)
{ assert(irq == 42 && fn == cci_isr && data == allocated); return fail_irq ? -EBUSY : 0; }
static void cci_init(struct cci *c) { assert(c == allocated && clock_on); init_calls++; }
static void pm_runtime_set_autosuspend_delay(struct device *d, unsigned delay)
{ assert(delay == MSEC_PER_SEC); }
static int devm_pm_runtime_set_active_enabled(struct device *d) { return fail_pm ? -EIO : 0; }
static void pm_runtime_use_autosuspend(struct device *d) { }
static int i2c_add_adapter(struct i2c_adapter *a)
{ added++; return fail_adapter == added ? -EIO : 0; }
static void i2c_del_adapter(struct i2c_adapter *a) { deleted++; }
#include "after-cci_isr.h"
#include "after-cci_reset.h"
#define cci_probe before_probe
#include "before-cci_probe.h"
#undef cci_probe
#define cci_probe after_probe
#include "after-cci_probe.h"
#undef cci_probe
static void clear(void)
{
 free(allocated); allocated = NULL;
 memset(mmio, 0, sizeof(mmio));
 initialized = writes = added = deleted = resets = clock_on = init_calls = 0;
 fail_irq = timeout_reset = fail_pm = fail_adapter = 0;
 missing_match = baseline_control = false;
}
int main(int argc, char **argv)
{
 struct device_node m1 = {1, NULL}, m0 = {0, &m1}, invalid = {2, NULL};
 struct platform_device p = {0};
 if (argc == 2 && !strcmp(argv[1], "before")) {
  clear(); baseline_control = true; p.dev.of_node = &m1;
  (void)before_probe(&p);
  assert(!"Original completion failure must be detected");
 }
 assert(argc == 1);
 clear(); p.dev.of_node = &m0; m0.next = NULL;
 assert(!before_probe(&p) && initialized == 1 && added == 1 && resets == 1);
 for (unsigned topology = 0; topology < 5; topology++) {
  clear(); profile.num_masters = 2;
  m0.next = topology == 3 ? &m1 : NULL;
  p.dev.of_node = topology == 0 ? NULL : topology == 1 ? &m0 :
                  topology == 2 ? &m1 : topology == 3 ? &m0 : &invalid;
  assert(after_probe(&p) == 0 && initialized == 2 && resets == 1 && init_calls == 1);
  assert(clock_on && added == (topology == 3 ? 2U : topology == 1 || topology == 2 ? 1U : 0U));
 }
 clear(); profile.num_masters = 1; p.dev.of_node = &m0; m0.next = NULL;
 assert(!after_probe(&p) && initialized == 1 && added == 1 && resets == 1);
 profile.num_masters = 2;
 for (unsigned failure = 0; failure < 5; failure++) {
  clear(); p.dev.of_node = &m0; m0.next = &m1;
  if (failure == 0) fail_irq = 1;
  if (failure == 1) timeout_reset = 1;
  if (failure == 2) fail_pm = 1;
  if (failure >= 3) fail_adapter = failure - 2;
  int expected = failure == 0 ? -EBUSY : failure == 1 ? -ETIMEDOUT : -EIO;
  assert(after_probe(&p) == expected && initialized == 2 && !clock_on);
  assert(deleted == (failure == 4 ? 1U : 0U));
 }
 clear(); missing_match = true;
 assert(after_probe(&p) == -ENOENT && !initialized && !writes && !clock_on);
 clear();
 puts("Actual CCI probe/reset/IRQ: master-1-only, master-0-only, both, empty/invalid children, one-master variant, five cleanup errors and missing match pass; fake boundaries only");
 return 0;
}
