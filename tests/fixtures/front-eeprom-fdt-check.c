/* SPDX-License-Identifier: GPL-2.0-only */
/* Synthetic board contracts; no fitted EEPROM data or physical validation. */
#include <assert.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <libfdt.h>
#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))
#define UKE_INIT
#include "uke-front-eeprom-dt.h"
#include "qup-scope.h"
static _Alignas(8) char tree[65536], before[65536];
static int p(const char *path) { int n = fdt_path_offset(tree, path); assert(n >= 0); return n; }
static int addpath(const char *path)
{
 char component[128]; int parent = 0; const char *part = path + 1;
 while (*part) {
  const char *end = strchr(part, '/');
  size_t bytes = end ? (size_t)(end - part) : strlen(part);
  assert(bytes && bytes < sizeof(component));
  memcpy(component, part, bytes); component[bytes] = 0;
  int node = fdt_subnode_offset(tree, parent, component);
  if (node == -FDT_ERR_NOTFOUND) node = fdt_add_subnode(tree, parent, component);
  assert(node >= 0); parent = node;
  if (!end) break;
  part = end + 1;
 }
 return parent;
}
static void s(const char *path, const char *key, const char *value)
{ assert(!fdt_setprop_string(tree, p(path), key, value)); }
static void u(const char *path, const char *key, unsigned value)
{ assert(!fdt_setprop_u32(tree, p(path), key, value)); }
static void b(const char *path, const char *key)
{ assert(!fdt_setprop(tree, p(path), key, NULL, 0)); }
static void a(const char *path, const char *key, const unsigned *values, unsigned count)
{
 fdt32_t encoded[16]; assert(count <= ARRAY_SIZE(encoded));
 for (unsigned i = 0; i < count; i++) encoded[i] = cpu_to_fdt32(values[i]);
 assert(!fdt_setprop(tree, p(path), key, encoded, count * sizeof(*encoded)));
}
#define A(path, key, ...) do { const unsigned v[] = {__VA_ARGS__}; a(path, key, v, ARRAY_SIZE(v)); } while (0)
static void pin(const char *path, unsigned ph, const char *pins, int bytes,
                const char *function, const char *bias)
{
 char sub[512]; addpath(path); u(path, "phandle", ph);
 snprintf(sub, sizeof(sub), "%s/mux", path); addpath(sub);
 assert(!fdt_setprop(tree, p(sub), "pins", pins, bytes)); s(sub, "function", function);
 snprintf(sub, sizeof(sub), "%s/config", path); addpath(sub);
 assert(!fdt_setprop(tree, p(sub), "pins", pins, bytes)); u(sub, "drive-strength", 2); b(sub, bias);
}
static void reset(void)
{
 assert(!fdt_create_empty_tree(tree, sizeof(tree)));
 const char root[] = "xiaomi,uke\0qcom,sm7675";
 assert(!fdt_setprop(tree, 0, "compatible", root, sizeof(root)));
 addpath(UKE_FRONT_QUP); s(UKE_FRONT_QUP, "compatible", "qcom,geni-se-qup");
 s(UKE_FRONT_QUP, "status", "okay"); A(UKE_FRONT_QUP, "reg", 0x8c0000, 0x2000);
 u(UKE_FRONT_QUP, "#address-cells", 1); u(UKE_FRONT_QUP, "#size-cells", 1);
 A(UKE_FRONT_QUP, "clocks", 10, 106, 10, 107); A(UKE_FRONT_QUP, "iommus", 12, 0x423, 0);
 const char wrapper_names[] = "m-ahb\0s-ahb";
 assert(!fdt_setprop(tree, p(UKE_FRONT_QUP), "clock-names", wrapper_names, sizeof(wrapper_names)));
 addpath("/soc/apps-smmu@15000000"); u("/soc/apps-smmu@15000000", "phandle", 12);
 u("/soc/apps-smmu@15000000", "#iommu-cells", 2);
 const char *gcc = "/soc/clock-controller@100000";
 addpath(gcc); u(gcc, "phandle", 10); u(gcc, "#clock-cells", 1); s(gcc, "compatible", "qcom,cliffs-gcc");
 const char *gpi = "/soc/qcom,gpi-dma@800000";
 addpath(gpi); u(gpi, "phandle", 11); u(gpi, "#dma-cells", 3); u(gpi, "dma-channels", 12);
 u(gpi, "dma-channel-mask", 0x1e); s(gpi, "compatible", "qcom,sm8450-gpi-dma"); s(gpi, "status", "okay");
 A(gpi, "reg", 0x800000, 0x60000); A(gpi, "iommus", 12, 0x436, 0);
 const char *icc[] = {"/soc/interconnect@0", "/soc/interconnect@24100000",
  "/soc/interconnect@1600000", "/soc/interconnect@1700000", "/soc/interconnect@1"};
 const unsigned cells[] = {1, 2, 1, 1, 2};
 for (unsigned i = 0; i < ARRAY_SIZE(icc); i++) {
  addpath(icc[i]); u(icc[i], "phandle", 20 + i); u(icc[i], "#interconnect-cells", cells[i]);
 }
 addpath(UKE_FRONT_TLMM); s(UKE_FRONT_TLMM, "compatible", "qcom,cliffs-pinctrl");
 u(UKE_FRONT_TLMM, "#gpio-cells", 2);
 A(UKE_FRONT_TLMM, "reg", 0xf000000, 0x1000000);
 pin(UKE_FRONT_PIN "uke_qupv3_se8_i2c_sda_active", 30, "gpio0", sizeof("gpio0"), "qup1_se0_l0", "bias-disable");
 pin(UKE_FRONT_PIN "uke_qupv3_se8_i2c_scl_active", 31, "gpio1", sizeof("gpio1"), "qup1_se0_l1", "bias-disable");
 pin(UKE_FRONT_PIN "qupv3_se8_i2c_sleep", 32, "gpio0\0gpio1", sizeof("gpio0\0gpio1"), "gpio", "bias-pull-down");
 addpath(UKE_FRONT_L20); u(UKE_FRONT_L20, "phandle", 40);
 s(UKE_FRONT_L20, "regulator-name", "pmxr2230_l20");
 u(UKE_FRONT_L20, "regulator-min-microvolt", 1620000);
 u(UKE_FRONT_L20, "regulator-max-microvolt", 3544000);
 u(UKE_FRONT_L20, "qcom,init-voltage", 1620000);
 const char *vrm = "/soc/rsc@17a00000/drv@2/rpmh-regulator-ldob20";
 s(vrm, "compatible", "qcom,rpmh-vrm-regulator");
 s(vrm, "qcom,resource-name", "ldob20"); s(vrm, "qcom,regulator-type", "pmic5-ldo");
 addpath(UKE_FRONT_BUS); s(UKE_FRONT_BUS, "compatible", "qcom,i2c-geni");
 s(UKE_FRONT_BUS, "status", "disabled"); u(UKE_FRONT_BUS, "#address-cells", 1); u(UKE_FRONT_BUS, "#size-cells", 0);
 A(UKE_FRONT_BUS, "reg", 0x880000, 0x4000); A(UKE_FRONT_BUS, "interrupts", 0, 373, 4);
 A(UKE_FRONT_BUS, "clocks", 10, 86); s(UKE_FRONT_BUS, "clock-names", "se-clk");
 A(UKE_FRONT_BUS, "dmas", 11, 0, 0, 3, 1024, 0, 11, 1, 0, 3, 1024, 0);
 const char dma[] = "tx\0rx", names[] = "qup-core\0qup-config\0qup-memory", pins[] = "default\0sleep";
 assert(!fdt_setprop(tree, p(UKE_FRONT_BUS), "dma-names", dma, sizeof(dma)));
 assert(!fdt_setprop(tree, p(UKE_FRONT_BUS), "interconnect-names", names, sizeof(names)));
 assert(!fdt_setprop(tree, p(UKE_FRONT_BUS), "pinctrl-names", pins, sizeof(pins)));
 A(UKE_FRONT_BUS, "interconnects", 20, 37, 20, 573, 21, 2, 0, 22, 541, 23, 7, 24, 512, 0);
 A(UKE_FRONT_BUS, "pinctrl-0", 30, 31); A(UKE_FRONT_BUS, "pinctrl-1", 32);
 u(UKE_FRONT_BUS, "qcom,clk-freq-out", 400000); b(UKE_FRONT_BUS, "qcom,pm-ctrl-client");
 addpath(UKE_FRONT_OLD); s(UKE_FRONT_OLD, "compatible", "qcom,cam-i2c-eeprom");
 s(UKE_FRONT_OLD, "status", "disabled"); u(UKE_FRONT_OLD, "phandle", 41); u(UKE_FRONT_OLD, "reg", 0x51);
 u(UKE_FRONT_OLD, "cam_vio-supply", 40); u(UKE_FRONT_OLD, "cell-index", 1);
 s(UKE_FRONT_OLD, "regulator-names", "cam_vio"); b(UKE_FRONT_OLD, "rgltr-cntrl-support");
 u(UKE_FRONT_OLD, "rgltr-min-voltage", 1800000); u(UKE_FRONT_OLD, "rgltr-max-voltage", 1800000);
 u(UKE_FRONT_OLD, "rgltr-load-current", 106000); s(UKE_FRONT_OLD, "label", "synthetic-label");
 const char *sensor = UKE_FRONT_BUS "/qcom,cam-sensor1";
 addpath(sensor); s(sensor, "compatible", "qcom,cam-i2c-sensor"); s(sensor, "status", "disabled"); u(sensor, "eeprom-src", 41);
 const char *aliases[] = {UKE_FRONT_QUP "/spi@880000", UKE_FRONT_QUP "/i3c-master@880000"};
 for (unsigned i = 0; i < ARRAY_SIZE(aliases); i++) {
  addpath(aliases[i]); A(aliases[i], "reg", 0x880000, 0x4000); s(aliases[i], "status", "disabled");
 }
 addpath(UKE_FRONT_QUP "/i2c@890000"); s(UKE_FRONT_QUP "/i2c@890000", "status", "okay");
 A(UKE_FRONT_QUP "/i2c@890000", "reg", 0x890000, 0x4000);
 s(UKE_FRONT_QUP "/i2c@890000", "synthetic-unrelated", "unchanged");
 addpath("/unrelated/rtc"); s("/unrelated/rtc", "status", "okay");
 addpath("/soc/qcom,qupv3_0_geni_se@ac0000");
 addpath("/__symbols__"); s("/__symbols__", "eeprom_front", UKE_FRONT_OLD);
}
static void refused(void)
{
 memcpy(before, tree, sizeof(tree)); assert(uke_front_eeprom_graph(tree) < 0);
 assert(!memcmp(before, tree, sizeof(tree)));
}
int main(void)
{
 reset(); assert(!uke_front_eeprom_graph(tree));
 assert(fdt_path_offset(tree, UKE_FRONT_OLD) == -FDT_ERR_NOTFOUND);
 assert(!fdt_node_check_compatible(tree, p(UKE_FRONT_NEW), "atmel,24c64"));
 assert(uke_front_u32(tree, p(UKE_FRONT_NEW), "phandle", 41));
 assert(uke_front_u32(tree, p(UKE_FRONT_NEW), "reg", 0x51));
 assert(uke_front_u32(tree, p(UKE_FRONT_NEW), "vcc-supply", 40));
 assert(uke_front_u32(tree, p(UKE_FRONT_NEW), "vcc-microvolt", 1800000));
 assert(uke_front_u32(tree, p(UKE_FRONT_NEW), "size", 8192));
 assert(uke_front_u32(tree, p(UKE_FRONT_NEW), "address-width", 16));
 assert(uke_front_bytes(tree, p(UKE_FRONT_NEW), "read-only", "", 0));
 assert(!fdt_getprop(tree, p(UKE_FRONT_NEW), "cam_vio-supply", NULL));
 assert(uke_front_u32(tree, p(UKE_FRONT_L20), "qcom,init-voltage", 1620000));
 assert(uke_front_disabled(tree, p(UKE_FRONT_BUS "/qcom,cam-sensor1")));
 assert(uke_front_u32(tree, p(UKE_FRONT_BUS "/qcom,cam-sensor1"), "eeprom-src", 41));
 assert(uke_front_disabled(tree, p(UKE_FRONT_QUP "/spi@880000")));
 assert(uke_front_disabled(tree, p(UKE_FRONT_QUP "/i3c-master@880000")));
 assert(!strcmp(fdt_getprop(tree, p("/__symbols__"), "eeprom_front", NULL), UKE_FRONT_NEW));
 assert(!strcmp(fdt_getprop(tree, p(UKE_FRONT_QUP "/i2c@890000"), "synthetic-unrelated", NULL), "unchanged"));
 assert(!strcmp(fdt_getprop(tree, p("/unrelated/rtc"), "status", NULL), "okay"));
 const unsigned expected_dma[] = {11, 0, 0, 3, 11, 1, 0, 3}; int bytes;
 const fdt32_t *dma = fdt_getprop(tree, p(UKE_FRONT_BUS), "dmas", &bytes);
 assert(dma && bytes == 32);
 for (unsigned i = 0; i < ARRAY_SIZE(expected_dma); i++) assert(fdt32_to_cpu(dma[i]) == expected_dma[i]);
 memcpy(before, tree, sizeof(tree)); assert(!uke_front_eeprom_graph(tree)); assert(!memcmp(before, tree, sizeof(tree)));
 reset(); s("/", "compatible", "xiaomi,other"); refused();
 const struct { const char *path, *key; unsigned bad; } cases[] = {
  {UKE_FRONT_BUS, "reg", 0x880004}, {UKE_FRONT_BUS, "interrupts", 373},
  {UKE_FRONT_BUS, "clocks", 86}, {UKE_FRONT_BUS, "dmas", 11},
  {UKE_FRONT_BUS, "interconnects", 20}, {UKE_FRONT_BUS, "pinctrl-0", 31},
  {UKE_FRONT_BUS, "#size-cells", 1}, {UKE_FRONT_QUP, "#address-cells", 2},
  {UKE_FRONT_QUP, "iommus", 12}, {UKE_FRONT_QUP, "clocks", 10},
  {UKE_FRONT_TLMM, "reg", 0xf000004},
  {"/soc/qcom,gpi-dma@800000", "iommus", 12},
  {"/soc/qcom,gpi-dma@800000", "reg", 0x800004},
  {UKE_FRONT_OLD, "reg", 0x50}, {UKE_FRONT_OLD, "cam_vio-supply", 10},
  {UKE_FRONT_OLD, "rgltr-min-voltage", 1620000},
  {UKE_FRONT_OLD, "rgltr-max-voltage", 3544000}, {UKE_FRONT_OLD, "phandle", 0},
  {UKE_FRONT_L20, "regulator-min-microvolt", 1800000},
  {"/soc/qcom,gpi-dma@800000", "#dma-cells", 5},
  {"/soc/interconnect@24100000", "#interconnect-cells", 1},
  {UKE_FRONT_PIN "uke_qupv3_se8_i2c_sda_active/config", "drive-strength", 4}
 };
 for (unsigned i = 0; i < ARRAY_SIZE(cases); i++) {
  reset(); u(cases[i].path, cases[i].key, cases[i].bad); refused();
 }
 reset(); s(UKE_FRONT_QUP, "firmware-name", "unreviewed"); refused();
 reset(); s(UKE_FRONT_BUS, "status", "okay"); refused();
 reset(); s(UKE_FRONT_BUS "/qcom,cam-sensor1", "status", "okay"); refused();
 reset(); s(UKE_FRONT_QUP "/spi@880000", "status", "okay"); refused();
 reset(); s(UKE_FRONT_QUP "/i3c-master@880000", "status", "okay"); refused();
 reset(); b(UKE_FRONT_OLD, "wp-gpios"); refused();
 reset(); addpath(UKE_FRONT_BUS "/unknown@51"); s(UKE_FRONT_BUS "/unknown@51", "status", "okay"); refused();
 reset(); b(UKE_FRONT_PIN "uke_qupv3_se8_i2c_sda_active/config", "bias-pull-up"); refused();
 reset(); s("/__symbols__", "eeprom_front", "/foreign"); refused();
 reset(); assert(!uke_front_eeprom_graph(tree)); assert(!fdt_delprop(tree, p(UKE_FRONT_NEW), "read-only")); refused();
 reset(); assert(!uke_front_eeprom_graph(tree)); u(UKE_FRONT_NEW, "vcc-microvolt", 1620000); refused();
 reset(); assert(!uke_front_eeprom_graph(tree)); assert(!uke_scope_qup_buses(tree));
 assert(uke_front_disabled(tree, p(UKE_FRONT_BUS))); /* Wrong ordering control. */
 reset(); assert(!uke_scope_qup_buses(tree)); assert(!uke_front_eeprom_graph(tree));
 assert(!strcmp(fdt_getprop(tree, p(UKE_FRONT_BUS), "status", NULL), "okay"));
 reset(); assert(!fdt_delprop(tree, p("/__symbols__"), "eeprom_front")); assert(!uke_front_eeprom_graph(tree));
 assert(!fdt_getprop(tree, p("/__symbols__"), "eeprom_front", NULL));
 reset(); assert(!fdt_del_node(tree, p("/__symbols__"))); assert(!uke_front_eeprom_graph(tree));
 puts("Actual front EEPROM FDT: exact bus/DMA/ICC/pins/VIO, 8K read-only profile, retained phandle/symbol/sensor quarantine and unrelated nodes pass; malformed/foreign graphs refuse before mutation; synthetic only");
 return 0;
}
