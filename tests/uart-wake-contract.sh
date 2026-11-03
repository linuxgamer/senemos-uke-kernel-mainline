#!/usr/bin/env bash
# Compile the actual GENI probe block with host-only PM/OF stubs.
set -Eeuo pipefail
[[ $# == 1 && -f $1 ]]
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
awk '/^\tif \(port->wakeup_irq > 0\) \{$/{copy=1;count++} copy&&/^\tdevm_pm_runtime_enable/{exit} copy{print} END{if(count!=1)exit 1}' "$1" > "$work/block.c"
cat > "$work/test.c" <<'EOF'
#include <assert.h>
#include <stdbool.h>
#include <string.h>
struct device_node { int unused; } child;
struct device { struct device_node *of_node; };
struct platform_device { struct device dev; };
struct port { int wakeup_irq; };
struct uart_port { unsigned int line; };
static int port_ida, ordinary_calls, reverse_calls, puts, frees, api_error;
static bool matching_child, wake_enabled;
static struct device_node *of_get_compatible_child(struct device_node *parent, const char *compatible)
{
    assert(parent == &child);
    assert(!strcmp(compatible, "xiaomi,uke-wcn6750-bt"));
    return matching_child ? &child : 0;
}
static void of_node_put(struct device_node *node) { puts += node != 0; }
static void device_init_wakeup(struct device *dev, bool enabled) { (void)dev; wake_enabled = enabled; }
static int dev_pm_set_dedicated_wake_irq(struct device *dev, int irq)
{ (void)dev; assert(irq == 135); ordinary_calls++; return api_error; }
static int dev_pm_set_dedicated_wake_irq_reverse(struct device *dev, int irq)
{ (void)dev; assert(irq == 135); reverse_calls++; return api_error; }
static void ida_free(int *ida, unsigned int line) { assert(ida == &port_ida && line == 1); frees++; }
static int probe_block(struct platform_device *pdev, struct port *port, struct uart_port *uport)
{
    int ret;
EOF
cat "$work/block.c" >> "$work/test.c"
cat >> "$work/test.c" <<'EOF'
    return 0;
error:
    return ret;
}
int main(void)
{
    struct platform_device pdev = { .dev.of_node = &child };
    struct uart_port uport = { .line = 1 };
    for (int match = 0; match <= 1; match++) {
        for (int error = 0; error >= -5; error -= 5) {
            for (int irq = -1; irq <= 135; irq += irq < 0 ? 1 : 135) {
                struct port port = { .wakeup_irq = irq };
                ordinary_calls = reverse_calls = puts = frees = 0;
                matching_child = match; api_error = error; wake_enabled = false;
                assert(probe_block(&pdev, &port, &uport) == (irq > 0 ? error : 0));
                assert(ordinary_calls == (irq > 0 && !match));
                assert(reverse_calls == (irq > 0 && match));
                assert(puts == (irq > 0 && match));
                assert(frees == (irq > 0 && error != 0));
                assert(wake_enabled == (irq > 0 && error == 0));
            }
        }
    }
}
EOF
cc -std=c11 -Wall -Wextra -Werror "$work/test.c" -o "$work/test"
"$work/test"
printf '%s\n' 'GENI Uke/generic wake selection, missing IRQ, OF references and PM error cleanup passed; host only.'
