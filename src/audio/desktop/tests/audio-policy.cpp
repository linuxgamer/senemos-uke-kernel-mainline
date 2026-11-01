// SPDX-License-Identifier: MIT
// Parse the shipped ALSA data and its merged control namespace without a device.
#include <alsa/asoundlib.h>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <string>

static snd_config_t *lookup(snd_config_t *root, const std::string &key)
{
    snd_config_t *value = nullptr;
    assert(snd_config_search(root, key.c_str(), &value) == 0);
    return value;
}

static void integer(snd_config_t *root, const std::string &key, long expected)
{
    long actual = -1;
    assert(snd_config_get_integer(lookup(root, key), &actual) == 0);
    assert(actual == expected);
}

static void text(snd_config_t *root, const std::string &key, const char *expected)
{
    const char *actual = nullptr;
    assert(snd_config_get_string(lookup(root, key), &actual) == 0);
    assert(std::strcmp(actual, expected) == 0);
}

static void microphones(snd_config_t *config)
{
    auto *devices = lookup(config, "SectionDevice");
    int count = 0;
    snd_config_iterator_t it, end;
    snd_config_for_each(it, end, devices) { ++count; }
    assert(count == 1);
    const std::string device = "SectionDevice.Mic";
    const auto value = device + ".Value.";
    text(config, device + ".Comment", "${CardLongName} Microphone");
    integer(config, value + "CaptureChannels", 4);
    integer(config, value + "CaptureRate", 48000);
    text(config, value + "CapturePCM", "hw:${CardId},2");
    for (int channel = 0; channel < 4; ++channel) {
        snd_config_t *unused = nullptr;
        const auto index = std::to_string(channel);
        assert(snd_config_search(config, (value + "CaptureChannel" + index).c_str(), &unused) < 0);
        assert(snd_config_search(config, (value + "CaptureChannelPos" + index).c_str(), &unused) < 0);
    }
    for (const char *sequence : {"EnableSequence", "DisableSequence"}) {
        auto *node = lookup(config, device + "." + sequence);
        assert(snd_config_iterator_first(node) == snd_config_iterator_end(node));
    }
}

int main(int argc, char **argv)
{
    assert(argc > 1);
    for (int i = 1; i < argc; ++i) {
        snd_config_t *config = nullptr;
        snd_input_t *input = nullptr;
        assert(snd_config_top(&config) == 0);
        assert(snd_input_stdio_open(&input, argv[i], "r") == 0);
        const int result = snd_config_load(config, input);
        if (result < 0)
            std::fprintf(stderr, "%s: %s\n", argv[i], snd_strerror(result));
        assert(result == 0);
        if (std::strstr(argv[i], "/Microphone-HiFi.conf"))
            microphones(config);
        snd_input_close(input);
        snd_config_delete(config);
    }
    return 0;
}
