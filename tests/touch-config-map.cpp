// SPDX-License-Identifier: GPL-2.0-or-later
// Compare all 2,400 entries of each generic OEM axis map with the compiled DT.
#include <cassert>
#include <fstream>
#include <iterator>
#include <sstream>
#include <string>
#include <vector>

int main(int argc, char **argv) {
    assert(argc == 4);
    std::ifstream file(argv[1], std::ios::binary);
    const std::string data{std::istreambuf_iterator<char>(file), {}};
    assert(file && data.size() >= 36000 && data.size() <= 37000);
    for (unsigned axis = 0; axis < 2; ++axis) {
        const std::string key = axis ? "default_mapping_y={" : "default_mapping_x={";
        const auto key_start = data.find(key);
        assert(key_start != std::string::npos);
        const auto begin = key_start + key.size(), end = data.find('}', begin);
        assert(end != std::string::npos && end - begin < 20000);
        auto values = data.substr(begin, end - begin);
        for (char &c : values) if (c == ',' || c == '\\') c = ' ';
        std::istringstream oem(values), dt(argv[axis + 2]);
        std::vector<int> map(axis ? 60 : 40);
        for (int &value : map) assert(dt >> value);
        assert((dt >> std::ws).eof());
        for (unsigned node = 0; node < 2400; ++node) {
            int value = 0;
            assert(oem >> value);
            assert(value > 0 && value < (axis ? 3200 : 2136));
            assert(value * 10 == map[axis ? node % 60 : node / 60]);
        }
        assert((oem >> std::ws).eof());
    }
}
