// SPDX-License-Identifier: GPL-2.0-only
// Host-only metadata reader; never exports tuning data or contacts a device.
// Format reference: AudioReach graphservices 76d04ffb, BSD-3-Clause,
// acdb_parser.c, DataProcSearchGkv{KeyTable,Lut}, BuildSubgraphDataRsp.
#include <cstdint>
#include <fstream>
#include <iostream>
#include <map>
#include <set>
#include <span>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {
using Bytes = std::vector<uint8_t>;
using View = std::span<const uint8_t>;
void require(bool ok, const char *why) {
    if (!ok) throw std::runtime_error(why);
}
struct Cursor {
    View data;
    View take(size_t count) {
        if (count > data.size())
            throw std::runtime_error("truncated ACDB field: need " +
                                     std::to_string(count) + ", have " + std::to_string(data.size()));
        auto result = data.first(count);
        data = data.subspan(count);
        return result;
    }
    uint32_t word() {
        auto b = take(4);
        return uint32_t(b[0]) | uint32_t(b[1]) << 8 |
               uint32_t(b[2]) << 16 | uint32_t(b[3]) << 24;
    }
    uint32_t count(size_t stride) {
        auto value = word();
        require(value <= data.size() / stride, "ACDB count exceeds its table");
        return value;
    }
    void end() const { require(data.empty(), "unexpected ACDB table tail"); }
};
Cursor at(View data, size_t offset) {
    require(offset <= data.size(), "ACDB offset out of bounds");
    return {data.subspan(offset)};
}
struct Graph {
    uint32_t key, value;
    std::map<uint32_t, uint32_t> modules; // instance -> module ID
    std::set<uint32_t> subgraph_ids;
    struct Transport {
        uint32_t instance, parameter;
        Bytes payload;
        std::vector<std::pair<uint32_t, uint32_t>> keys;
        uint32_t tag;
        std::vector<uint32_t> selectors;
    };
    std::vector<Transport> transport;
};
std::map<std::string, View> chunks(View bytes) {
    Cursor file{bytes};
    require(file.word() == 0x42444341 && file.word() == 0, "not an ACDB data file");
    require(file.word() == file.data.size(), "ACDB declared size mismatch");
    std::map<std::string, View> result;
    while (!file.data.empty()) {
        auto tag = file.take(4);
        std::string name(tag.begin(), tag.end());
        auto size = file.word();
        require(result.emplace(name, file.take(size)).second, "duplicate ACDB chunk");
    }
    for (auto name : {"HEAD", "GKVT", "GKVL", "POOL"})
        require(result.contains(name), "required ACDB chunk absent");
    Cursor header{result.at("HEAD")};
    require(header.word() == 1, "unreviewed ACDB header version");
    return result;
}
void module_list(Cursor list, Graph &graph) {
    auto count = list.count(12);
    for (uint32_t i = 0; i < count; ++i) {
        list.word(); // subgraph
        list.word(); // container
        auto modules = list.count(8);
        for (uint32_t m = 0; m < modules; ++m) {
            auto id = list.word(), instance = list.word();
            require(id && instance, "zero module identity");
            require(graph.modules.emplace(instance, id).second, "duplicate module instance");
        }
    }
    list.end();
}
void subgraphs(View pool, uint32_t offset, Graph &graph) {
    auto source = at(pool, offset);
    auto size = source.word();
    Cursor table{source.take(size)};
    auto count = table.count(8);
    for (uint32_t i = 0; i < count; ++i) {
        graph.subgraph_ids.insert(table.word());
        auto object_size = table.word();
        Cursor object{table.take(object_size)};
        auto driver_size = object.word();
        object.take(driver_size); // driver/tuning payload deliberately not exported
        auto spf_size = object.word();
        Cursor spf{object.take(spf_size)};
        object.end();
        while (!spf.data.empty()) {
            spf.word(); // target instance
            auto parameter = spf.word(), parameter_size = spf.word();
            Cursor payload{spf.take(parameter_size)};
            spf.take((8 - parameter_size % 8) % 8);
            if (parameter == 0x08001002) module_list(payload, graph);
        }
    }
    table.end();
}
void transport_parameters(const std::map<std::string, View> &tables, Graph &graph,
                          Cursor def, Cursor dot,
                          const std::vector<std::pair<uint32_t, uint32_t>> &keys,
                          uint32_t tag = 0, const std::vector<uint32_t> &selectors = {}) {
    auto count = def.count(8);
    require(dot.count(4) == count, "parameter definition/offset count mismatch");
    for (uint32_t p = 0; p < count; ++p) {
        auto instance = def.word(), parameter = def.word(), offset = dot.word();
        if (!graph.modules.contains(instance)) continue;
        auto module = graph.modules.at(instance);
        bool tdm = module == 0x0700100e || module == 0x0700100f;
        bool dma = module == 0x07001023 || module == 0x07001024;
        if ((!tdm && !dma) ||
            (parameter != 0x0800101b && parameter != 0x0800106a &&
             parameter != 0x08001063 && parameter != 0x08001017 &&
             parameter != 0x0800113c)) continue;
        auto pool = at(tables.at("POOL"), offset);
        auto payload_size = pool.word();
        uint32_t expected = parameter == 0x0800101b ? 28 :
                            parameter == 0x0800106a ? 4 :
                            parameter == 0x0800113c ? 16 : 12;
        require(payload_size == expected, "unreviewed transport parameter size");
        auto payload = pool.take(payload_size);
        require(graph.transport.size() < 4096, "too many transport variants");
        graph.transport.push_back({instance, parameter, Bytes(payload.begin(), payload.end()),
                                   keys, tag, selectors});
    }
}
void transport_variants(const std::map<std::string, View> &tables, Graph &graph) {
    // AcdbFindModuleCKV / AcdbGetSubgraphCalibration; variants are not active settings.
    for (auto name : {"CSLU", "CAKT", "CDLU", "CDDE", "CDDO"})
        require(tables.contains(name), "required parameter table absent");
    Cursor subgraphs{tables.at("CSLU")};
    auto subgraph_count = subgraphs.count(8);
    for (uint32_t s = 0; s < subgraph_count; ++s) {
        auto id = subgraphs.word(), entries = subgraphs.count(8);
        for (uint32_t e = 0; e < entries; ++e) {
            auto key_offset = subgraphs.word(), lut_offset = subgraphs.word();
            if (!graph.subgraph_ids.contains(id)) continue;
            auto keys = at(tables.at("CAKT"), key_offset);
            auto key_count = keys.count(4);
            require(key_count <= 64, "unreviewed parameter key count");
            std::vector<uint32_t> key_ids;
            for (uint32_t k = 0; k < key_count; ++k) key_ids.push_back(keys.word());
            auto values = at(tables.at("CDLU"), lut_offset);
            require(values.word() == key_count, "parameter lookup key count mismatch");
            auto variants = values.count((size_t(key_count) + 3) * 4);
            for (uint32_t variant = 0; variant < variants; ++variant) {
                std::vector<std::pair<uint32_t, uint32_t>> key_vector;
                for (auto key : key_ids) key_vector.emplace_back(key, values.word());
                auto def_offset = values.word(), dot_offset = values.word();
                values.word(); // global/persistent DOT2 is not read
                transport_parameters(tables, graph, at(tables.at("CDDE"), def_offset),
                                     at(tables.at("CDDO"), dot_offset), key_vector);
            }
        }
    }
    subgraphs.end();
}
void tagged_transport(const std::map<std::string, View> &tables, Graph &graph) {
    for (auto name : {"MTKT", "MTLU", "MTDE", "MTDO"})
        require(tables.contains(name), "required tag table absent");
    Cursor tags{tables.at("MTKT")};
    auto count = tags.count(12);
    for (uint32_t t = 0; t < count; ++t) {
        auto subgraph = tags.word(), tag = tags.word(), lut_offset = tags.word();
        if (!graph.subgraph_ids.contains(subgraph)) continue;
        auto values = at(tables.at("MTLU"), lut_offset);
        auto key_count = values.word();
        require(key_count <= 64, "unreviewed tag key count");
        auto variants = values.count((size_t(key_count) + 2) * 4);
        for (uint32_t v = 0; v < variants; ++v) {
            std::vector<uint32_t> selectors;
            for (uint32_t k = 0; k < key_count; ++k) selectors.push_back(values.word());
            auto def_offset = values.word(), dot_offset = values.word();
            transport_parameters(tables, graph, at(tables.at("MTDE"), def_offset),
                                 at(tables.at("MTDO"), dot_offset), {}, tag, selectors);
        }
    }
    tags.end();
}
std::vector<Graph> audit(View bytes) {
    auto tables = chunks(bytes);
    Cursor keys{tables.at("GKVT")};
    auto count = keys.count(8);
    std::vector<Graph> result;
    for (uint32_t t = 0; t < count; ++t) {
        auto key_count = keys.word();
        require(key_count && key_count <= 64, "unreviewed graph key count");
        auto entries = keys.count((size_t(key_count) + 1) * 4);
        for (uint32_t e = 0; e < entries; ++e) {
            auto first_key = keys.word();
            keys.take((key_count - 1) * 4);
            auto lut_offset = keys.word();
            auto lut = at(tables.at("GKVL"), lut_offset);
            require(lut.word() == key_count, "graph lookup key count mismatch");
            auto values = lut.count((size_t(key_count) + 2) * 4);
            for (uint32_t v = 0; v < values; ++v) {
                auto first_value = lut.word();
                lut.take((key_count - 1) * 4);
                auto list_offset = lut.word(), data_offset = lut.word();
                require(list_offset < tables.at("POOL").size(), "graph list offset out of bounds");
                require(data_offset < tables.at("POOL").size(), "graph data offset out of bounds");
                // Only base speaker, microphone and VI graph identities, never calibration.
                if (key_count == 1 &&
                    ((first_key == 0xa2000000 && first_value == 0xa2000001) ||
                     (first_key == 0xa3000000 &&
                      (first_value == 0xa3000001 || first_value == 0xa3000009)))) {
                    Graph graph{first_key, first_value, {}, {}, {}};
                    try { subgraphs(tables.at("POOL"), data_offset, graph); }
                    catch (const std::runtime_error &error) {
                        throw std::runtime_error("base graph at POOL+" + std::to_string(data_offset) +
                                                 ": " + error.what());
                    }
                    require(!graph.modules.empty(), "selected graph has no module list");
                    transport_variants(tables, graph);
                    tagged_transport(tables, graph);
                    result.push_back(std::move(graph));
                }
            }
        }
    }
    keys.end();
    require(!result.empty(), "no selected base audio graphs");
    return result;
}
void append(Bytes &b, uint32_t value) {
    for (unsigned i = 0; i < 4; ++i) b.push_back(uint8_t(value >> (8 * i)));
}
void chunk(Bytes &b, const std::string &tag, const Bytes &payload) {
    b.insert(b.end(), tag.begin(), tag.end());
    append(b, payload.size());
    b.insert(b.end(), payload.begin(), payload.end());
}
Bytes fixture() {
    Bytes file, header, keys, lut, pool, object, spf, modules, cslu, cakt, cdlu, cdde, cddo;
    for (auto v : {1u, 1u, 0xa2000000u, 0u}) append(keys, v);
    keys.insert(keys.begin(), {1, 0, 0, 0}); // one key-table group
    for (auto v : {1u, 1u, 0xa2000001u, 0u, 0u}) append(lut, v);
    for (auto v : {1u, 0x4000u, 0x4001u, 1u, 0x0700100eu, 0x6000u}) append(modules, v);
    // Four-byte payload followed by the format's eight-byte alignment padding.
    for (auto v : {1u, 0x08001001u, 4u, 0u, 0u}) append(spf, v);
    for (auto v : {1u, 0x08001002u, uint32_t(modules.size())}) append(spf, v);
    spf.insert(spf.end(), modules.begin(), modules.end());
    append(object, 0); append(object, spf.size());
    object.insert(object.end(), spf.begin(), spf.end());
    append(pool, 12 + object.size()); append(pool, 1); append(pool, 0x4000);
    append(pool, object.size()); pool.insert(pool.end(), object.begin(), object.end());
    for (auto v : {1u, 0x4000u, 1u, 0u, 0u}) append(cslu, v);
    append(cakt, 0);
    for (auto v : {0u, 1u, 0u, 0u, 0u}) append(cdlu, v);
    for (auto v : {2u, 0x6000u, 0x0800101bu, 0x6000u, 0x08001017u}) append(cdde, v);
    append(cddo, 2); append(cddo, pool.size());
    append(pool, 28);
    for (auto v : {3u, 0u, 1u, 15u, 0x00200004u, 0u, 0u}) append(pool, v);
    append(cddo, pool.size());
    for (auto v : {12u, 48000u, 0x00040020u, 1u}) append(pool, v);
    append(header, 1);
    chunk(file, "HEAD", header); chunk(file, "GKVT", keys);
    chunk(file, "GKVL", lut); chunk(file, "POOL", pool);
    chunk(file, "CSLU", cslu); chunk(file, "CAKT", cakt); chunk(file, "CDLU", cdlu);
    chunk(file, "CDDE", cdde); chunk(file, "CDDO", cddo);
    Bytes mtkt, mtlu;
    for (auto v : {1u, 0x4000u, 0xc0000001u, 0u}) append(mtkt, v);
    for (auto v : {1u, 1u, 0xd0000001u, 0u, 0u}) append(mtlu, v);
    chunk(file, "MTKT", mtkt); chunk(file, "MTLU", mtlu);
    chunk(file, "MTDE", cdde); chunk(file, "MTDO", cddo);
    Bytes result; append(result, 0x42444341); append(result, 0); append(result, file.size());
    result.insert(result.end(), file.begin(), file.end());
    return result;
}
void self_test() {
    auto good = fixture();
    require(audit(good).at(0).modules.at(0x6000) == 0x0700100e, "module identity mismatch");
    auto graph = audit(good).at(0);
    require(graph.transport.size() == 4 && graph.transport.at(0).payload.size() == 28 &&
            graph.transport.at(1).payload.size() == 12,
            "allowlisted transport metadata missing");
    require(graph.transport.at(2).tag == 0xc0000001 &&
            graph.transport.at(2).selectors == std::vector<uint32_t>{0xd0000001},
            "tagged transport metadata missing");
    auto reject = [](const Bytes &bad) {
        bool refused = false;
        try { (void)audit(bad); } catch (const std::runtime_error &) { refused = true; }
        require(refused, "malformed ACDB accepted");
    };
    for (size_t i = 0; i < good.size(); ++i) {
        auto short_file = good; short_file.resize(i); reject(short_file);
    }
    for (size_t offset : {size_t(0), size_t(4), size_t(8), size_t(16), size_t(36),
                          good.size() - 12}) {
        auto bad = good;
        for (unsigned i = 0; i < 4; ++i) bad.at(offset + i) = 0xff;
        reject(bad);
    }
    for (auto [name, offset] : {std::pair{"MTKT", 0u}, {"MTKT", 12u},
                               {"MTLU", 0u}, {"MTLU", 4u}, {"MTLU", 12u},
                               {"MTLU", 16u}, {"MTDE", 0u}, {"MTDO", 4u}}) {
        auto position = size_t(chunks(good).at(name).data() - good.data()) + offset;
        auto bad = good;
        for (unsigned i = 0; i < 4; ++i) bad.at(position + i) = 0xff;
        reject(bad);
    }
    auto bad = good; bad.push_back(0); reject(bad);
    std::cout << "ACDB metadata and malformed-input fixtures passed; host only.\n";
}
}
int main(int argc, char **argv) {
    try {
        require(argc == 2, "usage: acdb-graph-audit FILE.acdb | --self-test");
        if (std::string(argv[1]) == "--self-test") { self_test(); return 0; }
        std::ifstream file(argv[1], std::ios::binary | std::ios::ate);
        require(bool(file), "cannot open ACDB file");
        auto size = file.tellg();
        require(size >= 12 && size <= 64 * 1024 * 1024, "ACDB file size out of bounds");
        Bytes bytes(size_t(size), 0);
        file.seekg(0); file.read(reinterpret_cast<char *>(bytes.data()), bytes.size());
        require(bool(file), "cannot read ACDB file");
        for (const auto &graph : audit(bytes)) {
            std::cout << "Graph key=0x" << std::hex << graph.key << " value=0x" << graph.value << '\n';
            for (auto [instance, module] : graph.modules)
                std::cout << "  module=0x" << module << " instance=0x" << instance << '\n';
            for (const auto &transport : graph.transport) {
                std::cout << "  transport instance=0x" << transport.instance << " parameter=0x"
                          << transport.parameter << " bytes=" << std::dec << transport.payload.size();
                for (auto [key, value] : transport.keys)
                    std::cout << " key[0x" << std::hex << key << "]=0x" << value;
                if (transport.tag) {
                    std::cout << " tag=0x" << std::hex << transport.tag << " selectors=";
                    for (auto value : transport.selectors) std::cout << "0x" << value << ',';
                }
                std::cout << std::dec;
                Cursor payload{transport.payload};
                if (transport.parameter == 0x0800101b) {
                    require(payload.data.size() == 28, "unreviewed TDM interface payload");
                    auto lpaif = payload.word(), index = payload.word();
                    auto sync_oe = payload.word(), mask = payload.word(), slots_width = payload.word();
                    auto mode_polarity = payload.word(), delay_reserved = payload.word();
                    std::cout << " lpaif=" << lpaif << " index=" << index
                              << " sync=" << (sync_oe & 0xffff) << " output-enable=" << (sync_oe >> 16)
                              << " slots=" << (slots_width & 0xffff) << " width=" << (slots_width >> 16)
                              << " mask=" << mask << " sync-mode=" << (mode_polarity & 0xffff)
                              << " polarity=" << (mode_polarity >> 16) << " delay=" << (delay_reserved & 0xffff);
                } else if (transport.parameter == 0x0800106a) {
                    require(payload.data.size() == 4, "unreviewed TDM lane payload");
                    std::cout << " lane-mask=" << (payload.word() & 0xffff);
                } else if (transport.parameter == 0x08001017) {
                    auto rate = payload.word(), width_channels = payload.word();
                    std::cout << " rate=" << rate << " width=" << (width_channels & 0xffff)
                              << " channels=" << (width_channels >> 16) << " format=" << payload.word();
                } else if (transport.parameter == 0x08001063) {
                    std::cout << " lpaif=" << payload.word() << " index=" << payload.word()
                              << " channel-mask=" << payload.word();
                } else if (transport.parameter == 0x0800113c) {
                    std::cout << " clock=" << payload.word() << " frequency=" << payload.word()
                              << " attribute=" << payload.word() << " root=" << payload.word();
                }
                std::cout << '\n' << std::hex;
            }
        }
        std::cout << "Metadata only; no calibration export or hardware qualification.\n";
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
