#!/usr/bin/env bash
# Exercise the production ELD notifier with changed bytes and control lifetimes.
set -Eeuo pipefail
source_file=${1:?Pass the prepared hdmi-codec.c}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cstdint>
#include <cstring>
#include <cstdio>
using u8 = uint8_t;
static constexpr unsigned SNDRV_CTL_EVENT_MASK_VALUE = 1;
struct snd_ctl_elem_id { unsigned numid, iface, device; };
struct snd_card { int controls_rwsem; };
struct snd_kcontrol { snd_ctl_elem_id id; };
struct snd_soc_card { struct snd_card *snd_card; };
struct device { device *parent; bool *of_node; };
struct snd_soc_component { snd_soc_card *card; device *dev; };
struct hdmi_codec_priv {
    snd_soc_component *component;
    snd_ctl_elem_id eld_ctl_id;
    u8 eld[128];
};
static unsigned notifications;
static snd_card card;
static snd_kcontrol control{{5, 3, 0}};
static bool control_present = true;
static void down_read(int *lock) { assert(lock == &card.controls_rwsem && *lock == 0); ++*lock; }
static void up_read(int *lock) { assert(lock == &card.controls_rwsem && *lock == 1); --*lock; }
static snd_kcontrol *snd_ctl_find_id(snd_card *target, const snd_ctl_elem_id *id) {
    assert(target == &card && card.controls_rwsem == 1 && id->numid == 5);
    return control_present ? &control : nullptr;
}
static bool of_device_is_compatible(const bool *node, const char *compatible) {
    assert(!std::strcmp(compatible, "qcom,sm7675-dp"));
    return node && *node;
}
static void snd_ctl_notify(snd_card *target, unsigned mask, snd_ctl_elem_id *id) {
    assert(target == &card && mask == SNDRV_CTL_EVENT_MASK_VALUE);
    assert(card.controls_rwsem == 1);
    assert(id->numid == 5 && id->iface == 3 && id->device == control.id.device);
    ++notifications;
}
CPP
awk '/^static void hdmi_codec_notify_eld\(/ {emit=1} emit {print} emit && /^}/ {exit}' \
    "$source_file" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
int main() {
    bool compatible = true;
    device parent{nullptr, &compatible}, dev{&parent, nullptr};
    snd_soc_card soc{&card};
    snd_soc_component component{&soc, &dev};
    hdmi_codec_priv hcp{&component, {5, 3, 16}, {}};
    u8 previous[128]{};
    hdmi_codec_notify_eld(&hcp, previous);
    assert(notifications == 0);
    hcp.eld[20] = 'V';
    hdmi_codec_notify_eld(&hcp, previous);
    assert(notifications == 1);
    assert(card.controls_rwsem == 0);
    control_present = false;
    hdmi_codec_notify_eld(&hcp, previous);
    assert(notifications == 1 && card.controls_rwsem == 0);
    control_present = true;
    compatible = false;
    hdmi_codec_notify_eld(&hcp, previous);
    parent.of_node = nullptr;
    hdmi_codec_notify_eld(&hcp, previous);
    parent.of_node = &compatible;
    compatible = true;
    hcp.eld_ctl_id.numid = 0;
    hdmi_codec_notify_eld(&hcp, previous);
    hcp.eld_ctl_id.numid = 5;
    component.card = nullptr;
    hdmi_codec_notify_eld(&hcp, previous);
    component.card = &soc;
    soc.snd_card = nullptr;
    hdmi_codec_notify_eld(&hcp, previous);
    soc.snd_card = &card;
    hcp.component = nullptr;
    hdmi_codec_notify_eld(&hcp, previous);
    assert(notifications == 1);
    hcp.component = &component;
    std::memcpy(previous, hcp.eld, sizeof(previous));
    hdmi_codec_notify_eld(&hcp, previous);
    assert(notifications == 1);
    std::memset(hcp.eld, 0, sizeof(hcp.eld));
    hdmi_codec_notify_eld(&hcp, previous);
    assert(notifications == 2);
    control.id.device = 18;
    hdmi_codec_notify_eld(&hcp, previous);
    assert(notifications == 3 && card.controls_rwsem == 0);
    puts("Actual Uke ELD notifier: current FE0/backend18 ID, balanced locks, changed/unchanged, disconnect, foreign parent, missing control/card and removal passed");
}
CPP
g++ -std=c++17 -Wall -Wextra -Werror "$work/check.cpp" -o "$work/check"
"$work/check"
