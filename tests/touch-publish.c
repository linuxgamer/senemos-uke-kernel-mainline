/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <assert.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include "../src/input/nt36532-uke-matrix.h"
#define MT_TOOL_FINGER 0
#define ABS_MT_POSITION_X 0
#define ABS_MT_POSITION_Y 1
#define msecs_to_jiffies(ms) (ms)
#define time_after(a,b) ((long)((b)-(a)) < 0)
static unsigned long jiffies = 1000;
struct input_mt_pos { int x, y; };
struct input_dev {
    bool active[10], seen[10];
    u16 x[10], y[10];
    unsigned int slot, frames, syncs;
};
struct touchscreen_properties { u16 max_x, max_y; bool invert_x, invert_y, swap_x_y; };
static const struct touchscreen_properties *properties;
struct spi_device { int dev; };
struct nvt_uke_touch {
    struct input_dev *wake_input;
    struct touchscreen_properties prop;
    struct spi_device *spi;
    struct nvt_uke_matrix matrix;
    u8 *frame;
    unsigned long last_valid;
    unsigned long long input_packets, input_errors;
    u16 contacts_active;
    u16 candidate_counter;
    u8 candidate_count;
    bool candidate_valid;
    struct input_mt_pos motion_center;
    u8 motion_slot;
    bool motion_valid;
};
static unsigned int warnings;
static int decode_error, assign_error;
static struct nvt_uke_contacts decoded;
static u16 next_counter;
static int assigned[] = { 9, 2, 8, 3, 7, 4, 6, 5, 1, 0 };
#define dev_warn_ratelimited(...) do { warnings++; } while (0)
int nvt_uke_decode(const u8 *data, size_t size, struct nvt_uke_frame *frame)
{
    assert(data && size == NVT_UKE_FRAME_SIZE);memset(frame, 0, sizeof(*frame));
    frame->counter = next_counter++;return decode_error;
}
int nvt_uke_matrix_process(struct nvt_uke_matrix *matrix, const struct nvt_uke_frame *frame,
    u16 max_x, u16 max_y, struct nvt_uke_contacts *contacts)
{
    assert(matrix && frame && max_x == 31999 && max_y == 21359);*contacts = decoded;return 0;
}
static int input_mt_assign_slots(struct input_dev *input, int *slots,
    const struct input_mt_pos *positions, unsigned int count, unsigned int distance)
{
    assert(input && count <= 10 && distance == 0);
    for (unsigned int i = 0; i < count; i++) {
        int x = properties->invert_x ? properties->max_x - decoded.x[i] : decoded.x[i];
        int y = properties->invert_y ? properties->max_y - decoded.y[i] : decoded.y[i];
        assert(positions[i].x == (properties->swap_x_y ? y : x));
        assert(positions[i].y == (properties->swap_x_y ? x : y));
        slots[i] = assigned[i];
    }
    return assign_error;
}
static void input_mt_slot(struct input_dev *input, unsigned int slot)
{
    assert(slot < 10);input->slot = slot;
}
static void input_mt_report_slot_state(struct input_dev *input, int tool, bool active)
{
    assert(tool == MT_TOOL_FINGER);input->active[input->slot] = active;input->seen[input->slot] = active;
}
static void touchscreen_set_mt_pos(struct input_mt_pos *position,
    const struct touchscreen_properties *prop, unsigned int x, unsigned int y)
{
    if (prop->invert_x)x = prop->max_x - x;
    if (prop->invert_y)y = prop->max_y - y;
    position->x = (int)(prop->swap_x_y ? y : x);
    position->y = (int)(prop->swap_x_y ? x : y);
}
static void input_report_abs(struct input_dev *input, int axis, int value)
{
    assert(value >= 0);
    if (axis == ABS_MT_POSITION_X)input->x[input->slot] = (u16)value;
    else {assert(axis == ABS_MT_POSITION_Y);input->y[input->slot] = (u16)value;}
}
void touchscreen_report_pos(struct input_dev *input,
    const struct touchscreen_properties *prop, int x, int y, bool mt)
{
    assert(mt && x >= 0 && y >= 0 && x <= prop->max_x && y <= prop->max_y);
    struct input_mt_pos position;
    touchscreen_set_mt_pos(&position, prop, (unsigned int)x, (unsigned int)y);
    input_report_abs(input, ABS_MT_POSITION_X, position.x);
    input_report_abs(input, ABS_MT_POSITION_Y, position.y);
}
static void input_mt_sync_frame(struct input_dev *input)
{
    for (unsigned int i = 0; i < 10; i++) {
        if (!input->seen[i])input->active[i] = false;
        input->seen[i] = false;
    }
    input->frames++;
}
static void input_sync(struct input_dev *input) { input->syncs++; }
#include "production-contacts.h"
int main(void)
{
    assert(nvt_stable_axis(1200,1000,266,31999) == 1000);
    assert(nvt_stable_axis(800,1000,266,31999) == 1000);
    assert(nvt_stable_axis(1500,1000,266,31999) == 1234);
    assert(nvt_stable_axis(500,1000,266,31999) == 766);
    assert(nvt_stable_axis(0,1000,266,31999) == 0);
    assert(nvt_stable_axis(31999,31000,266,31999) == 31999);
    const struct input_mt_pos original[3] = {{1000,2000},{4000,2000},{7000,2000}};
    for (unsigned int a = 0; a < 3; a++)
        for (unsigned int b = 0; b < 3; b++) {
            if (a == b)continue;
            const unsigned int c = 3 - a - b;
            struct input_mt_pos points[3] = {original[a],original[b],original[c]};
            int slots[3] = {0,1,2};
            nvt_order_new_slots(points,slots,3,0,7);
            for (unsigned int i = 0; i < 3; i++) {
                assert(points[i].x == (i == 0 ? original[a].x : i == 1 ? original[b].x : original[c].x));
                if (points[i].x == 4000)assert(slots[i] == 0);
                for (unsigned int j = 0; j < i; j++)assert(slots[i] != slots[j]);
            }
        }
    struct input_mt_pos points[3] = {{7000,2000},{1000,2000},{4000,2000}};
    int slots[3] = {0,1,2};
    nvt_order_new_slots(points,slots,3,1,7);
    assert(slots[0] == 0 && slots[2] == 1 && slots[1] == 2);
    slots[0]=5;slots[1]=1;slots[2]=2;
    nvt_order_new_slots(points,slots,3,1U<<5,3);
    assert(slots[0] == 5 && slots[1] == 1 && slots[2] == 2);
    nvt_order_new_slots(points,slots,2,0,3);
    assert(slots[0] == 5 && slots[1] == 1);
    nvt_order_new_slots(points,slots,1,0,1);
    assert(slots[0] == 5);
    u8 packet[NVT_UKE_FRAME_SIZE] = { 0 };
    struct input_dev input = { 0 };
    struct nvt_uke_touch touch = { .wake_input = &input, .prop = {.max_x=31999,.max_y=21359}, .frame = packet };
    properties = &touch.prop;
    nvt_publish_contacts(&touch, 0);
    assert(touch.input_packets == 1 && !touch.contacts_active && input.syncs == 1);
    decoded = (struct nvt_uke_contacts) { .active=3, .x={1000,2000}, .y={3000,4000}, .peak={650,650} };
    nvt_publish_contacts(&touch, 0);
    assert(!touch.contacts_active);
    next_counter--;nvt_publish_contacts(&touch, 0);
    assert(!touch.contacts_active); /* A duplicate packet is not a second observation. */
    nvt_publish_contacts(&touch, 0);
    assert(touch.contacts_active == 0x204 && input.active[9] && input.active[2]);
    assert(input.x[9] == 1000 && input.y[2] == 4000);
    decoded.active = 1;nvt_publish_contacts(&touch, 0);
    assert(touch.contacts_active == 0x200 && input.active[9] && !input.active[2]);
    decode_error = -5;jiffies += 50;nvt_publish_contacts(&touch, 0);
    assert(input.active[9] && touch.input_errors == 1);
    jiffies += 51;nvt_publish_contacts(&touch, 0);
    assert(!input.active[9] && !touch.contacts_active && warnings == 2);
    decode_error = 0;nvt_publish_contacts(&touch, 0);assert(!input.active[9]);
    nvt_publish_contacts(&touch, 0);assert(input.active[9]);
    assign_error = -5;nvt_publish_contacts(&touch, 0);assert(!input.active[9]);
    assign_error = 0;nvt_publish_contacts(&touch, 0);nvt_release_contacts(&touch);
    assert(!input.active[9] && !touch.contacts_active);
    for (unsigned int flags = 0; flags < 8; flags++) {
        touch.prop.invert_x = flags & 1;
        touch.prop.invert_y = flags & 2;
        touch.prop.swap_x_y = flags & 4;
        decoded.active = 3;
        nvt_publish_contacts(&touch, 0);assert(!touch.contacts_active);
        for (unsigned int held = 0; held < 200; held++) {
            nvt_publish_contacts(&touch, 0);
            assert(touch.contacts_active == 0x204 && input.active[9] && input.active[2]);
            int x = touch.prop.invert_x ? 30999 : 1000;
            int y = touch.prop.invert_y ? 18359 : 3000;
            assert(input.x[9] == (touch.prop.swap_x_y ? y : x));
            assert(input.y[9] == (touch.prop.swap_x_y ? x : y));
        }
        nvt_release_contacts(&touch);
    }
    /* Low peaks keep their assigned old slot, but cannot start a new touch. */
    decoded.active = 3;decoded.peak[0] = decoded.peak[1] = 90;
    nvt_publish_contacts(&touch, 0);assert(!touch.contacts_active);
    decoded.peak[0] = 120;
    nvt_publish_contacts(&touch, 0);assert(touch.contacts_active == 0x200);
    decoded.peak[0] = 90;decoded.peak[1] = 120;
    nvt_publish_contacts(&touch, 0);assert(touch.contacts_active == 0x204);
    decoded.peak[1] = 70;
    for (unsigned int held = 0; held < 200; held++) {
        nvt_publish_contacts(&touch, 0);assert(touch.contacts_active == 0x204);
    }
    decoded.active = 1;
    nvt_publish_contacts(&touch, 0);assert(touch.contacts_active == 0x200);
    nvt_release_contacts(&touch);
    nvt_publish_contacts(&touch, 0);assert(!touch.contacts_active);
    decoded.active = 0x3ff;
    for (unsigned int i = 0; i < 10; i++) {
        decoded.x[i] = (u16)(1000 + i * 2000);
        decoded.y[i] = (u16)(2000 + i * 1000);
        decoded.peak[i] = 120;
    }
    nvt_publish_contacts(&touch, 0);assert(!touch.contacts_active);
    nvt_publish_contacts(&touch, 0);assert(touch.contacts_active == 0x3ff);
    for (unsigned int i = 0; i < 10; i++)decoded.peak[i] = 80;
    for (unsigned int held = 0; held < 200; held++) {
        nvt_publish_contacts(&touch, 0);assert(touch.contacts_active == 0x3ff);
    }
    decoded.active = 0x1ff;
    nvt_publish_contacts(&touch, 0);assert(touch.contacts_active == 0x3fe);
    decoded.active = 0;
    nvt_publish_contacts(&touch, 0);assert(!touch.contacts_active);
    decoded.active = 3;decoded.peak[0] = decoded.peak[1] = 350;
    assigned[0] = -1;nvt_publish_contacts(&touch, 0);assert(!touch.contacts_active);
    assigned[0] = 9;decoded.active = 1;
    next_counter = 65535;
    nvt_publish_contacts(&touch, 0);assert(!touch.contacts_active);
    nvt_publish_contacts(&touch, 0);assert(touch.contacts_active == 0x200);
    decoded.active = 0;nvt_publish_contacts(&touch, 0);assert(!touch.contacts_active);
    decoded.active = 1;nvt_publish_contacts(&touch, 0);assert(!touch.contacts_active);
    decoded.active = 3;nvt_publish_contacts(&touch, 0);assert(!touch.contacts_active);
    decoded.active = 7;decoded.peak[2] = 350;
    nvt_publish_contacts(&touch, 0);assert(!touch.contacts_active);
    nvt_publish_contacts(&touch, 0);assert(__builtin_popcount(touch.contacts_active) == 3);
    decoded.active = 3;nvt_publish_contacts(&touch, 0);
    assert(__builtin_popcount(touch.contacts_active) == 2); /* Lifts do not wait. */
    nvt_release_contacts(&touch);
    touch.prop=(struct touchscreen_properties){.max_x=31999,.max_y=21359};
    decoded.active=1;decoded.x[0]=1000;decoded.y[0]=2000;decoded.peak[0]=350;
    nvt_publish_contacts(&touch,0);nvt_publish_contacts(&touch,0);
    assert(input.x[9] == 1000 && input.y[9] == 2000);
    decoded.x[0]=1200;decoded.y[0]=2200;nvt_publish_contacts(&touch,0);
    assert(input.x[9] == 1000 && input.y[9] == 2000);
    decoded.x[0]=2000;decoded.y[0]=3000;nvt_publish_contacts(&touch,0);
    assert(input.x[9] == 1734 && input.y[9] == 2734);
    decoded.active=3;decoded.x[0]=2100;decoded.y[0]=3100;decoded.peak[1]=350;
    nvt_publish_contacts(&touch,0);
    assert(input.x[9] == 2100 && input.y[9] == 3100); /* Multitouch bypasses stabilization. */
    decoded.active=0;nvt_publish_contacts(&touch,0);assert(!touch.motion_valid);
}
