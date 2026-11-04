// SPDX-License-Identifier: MIT
// Actual JSON converter and C wire/PA helpers, using synthetic inputs only.
#include "o82-color-profile.cpp"

namespace {
unsigned hsic_checks;
void hsic_check(bool value) {
    ++hsic_checks;
    if (!value) throw std::runtime_error("HSIC payload contract failed");
}
Json hsic_picture() {
    return parse(R"({"hue":42,"sat":0.5,"satThresh":0.5,"val":127.5,"cont":-0.5})");
}
void parser_wire() {
    auto picture=hsic_picture();
    const auto wire=native_hsic(picture.get());
    hsic_check(wire.size()==24 && o82_hsic_valid(wire.data(),wire.size()));
    constexpr unsigned words[]{15,0xb3,0x7f20,0x20,0xe0,0};
    for (unsigned i=0;i<6;i++) hsic_check(o82_hdr_u32(wire.data()+4*i)==words[i]);
    auto zero=parse(R"({"hue":0,"sat":-0.0,"satThresh":0,"val":0,"cont":0})");
    auto neutral=native_hsic(zero.get());
    hsic_check(o82_color_fw_zero(neutral.data(),neutral.size()));
    for (double value : {1e-100,-1e-100}) {
        hsic_check(!json_object_object_add(zero.get(),"sat",json_object_new_double(value)));
        neutral=native_hsic(zero.get());
        hsic_check(o82_color_fw_zero(neutral.data(),neutral.size()));
    }
    hsic_check(!json_object_object_add(zero.get(),"sat",json_object_new_double(std::numeric_limits<float>::denorm_min())));
    const auto tiny=native_hsic(zero.get());
    hsic_check(o82_hdr_u32(tiny.data())==15 && o82_color_fw_zero(tiny.data()+4,20));
    for (const char *key : {"hue","sat","satThresh","val","cont"}) {
        for (unsigned defect=0;defect<5;defect++) {
            auto bad=hsic_picture();
            if (defect==0) json_object_object_del(bad.get(),key);
            if (defect==1) hsic_check(!json_object_object_add(bad.get(),key,json_object_new_string("0")));
            if (defect==2) hsic_check(!json_object_object_add(bad.get(),key,json_object_new_boolean(false)));
            if (defect==3) hsic_check(!json_object_object_add(bad.get(),key,json_object_new_double(INFINITY)));
            if (defect==4) hsic_check(!json_object_object_add(bad.get(),key,json_object_new_double(1e100)));
            bool refused=false;
            try { (void)native_hsic(bad.get()); } catch (const std::runtime_error &) {refused=true;}
            hsic_check(refused);
        }
    }
    hsic_check(!json_object_object_add(picture.get(),"hue",json_object_new_double(0.5)));
    bool refused=false;
    try { (void)native_hsic(picture.get()); } catch (const std::runtime_error &) {refused=true;}
    hsic_check(refused);
    for (unsigned offset : {0u,4u,8u,12u,16u,20u}) {
        auto bad=wire;
        put_word(bad,offset,offset==0?1:offset==4?0x1000:offset==8?0x10000:offset==20?1:0x100);
        hsic_check(!o82_hsic_valid(bad.data(),bad.size()));
    }
    auto disabled=wire; put_word(disabled,0,0);
    hsic_check(!o82_hsic_valid(disabled.data(),disabled.size()));
    for (unsigned offset : {4u,8u,12u,16u}) {
        auto bad=wire; put_word(bad,offset,offset==4?769:66);
        hsic_check(!o82_hsic_valid(bad.data(),bad.size()));
    }
    hsic_check(!o82_hsic_valid(nullptr,24) && !o82_hsic_valid(wire.data(),23));
}
void composed_mode() {
    std::vector<unsigned char> six(O82_SIXZONE_BYTES);
    put_word(six,0,7); put_word(six,28,384); six[24]=six[25]=3;
    hsic_check(o82_sixzone_valid(six.data(),six.size()));
    const auto active=native_hsic(hsic_picture().get());
    std::array<unsigned char,24> neutral{};
    hsic_check(O82_PA_FULL_MODE_PRESERVE==0x01efffff);
    for (unsigned foreign=0;foreign<16;foreign++) {
        const unsigned other=(foreign&7)<<5 | (foreign>>3)<<16;
        for (unsigned old=0;old<256;old++) {
            const unsigned previous=0x01000f01 | other | (old&127)<<25 | (old>>7)<<20;
            for (unsigned enable_six=0;enable_six<2;enable_six++)
                for (unsigned enable_hsic=0;enable_hsic<2;enable_hsic++) {
                    const unsigned owned=(enable_six?0xe0000000u:0) | (enable_hsic?0x1e000000u:0);
                    const unsigned expected=0x01000f01 | other | owned | ((other||owned)?0x100000u:0);
                    hsic_check(o82_pa_mode(previous,enable_six?six.data():nullptr,
                                          enable_hsic?active.data():neutral.data())==expected);
                }
        }
    }
}
void bundle_wire() {
    const auto active=native_hsic(hsic_picture().get());
    for (unsigned enable=0;enable<2;enable++) {
        const size_t record=O82_COLOR_FW_HEADER,tables=record+O82_COLOR_FW_RECORD;
        const size_t hsic=tables+O82_COLOR_FW_DATA_BYTES;
        std::vector<unsigned char> bundle(hsic+24+1);
        std::memcpy(bundle.data(),O82_COLOR_FW_MAGIC,8);
        std::memcpy(bundle.data()+record,"synthetic",9);
        put_word(bundle,8,4); put_word(bundle,12,0x42); put_word(bundle,16,bundle.size());
        put_word(bundle,24,1); put_word(bundle,28,160); put_word(bundle,64,O82_HDR_NOMINAL_PEAK_NITS);
        put_word(bundle,68,O82_HDR_NOMINAL_BLACK_10000); put_word(bundle,72,tables);
        put_hash(bundle,32,"2b6442ce0e8fef6d1b008cdeca3838450282868d385f6e3056c0a4ce2b8949d8");
        put_word(bundle,record+72,5|(enable?8:0)); put_word(bundle,record+80,tables);
        put_word(bundle,record+84,O82_COLOR_FW_DATA_BYTES); bundle[record+96]=1;
        put_word(bundle,record+88,hsic+24); put_word(bundle,record+92,1); bundle.back()='x';
        put_word(bundle,record+144,hsic); put_word(bundle,record+148,24);
        for (unsigned curve=0;curve<2;curve++) for (unsigned c=0;c<3;c++) {
            const auto at=tables+curve*O82_COLOR_FW_CURVE_BYTES+(256*3+c)*2;
            bundle[at]=255; bundle[at+1]=15;
        }
        if (enable) std::copy(active.begin(),active.end(),bundle.begin()+hsic);
        auto seal=[&]{put_word(bundle,20,o82_hdr_crc32(bundle.data()+24,bundle.size()-24));};
        seal(); hsic_check(o82_color_fw_valid(bundle.data(),bundle.size(),0x42));
        const auto snapshot=bundle;
        const std::pair<size_t,unsigned> defects[]{
            {record+144,0},{record+148,23},{record+152,1},{record+76,1},
            {hsic+20,1},{hsic,enable?0u:15u},{record+72,enable?5u:13u}};
        for (const auto &[at,value] : defects) {
            bundle=snapshot; put_word(bundle,at,value); seal();
            hsic_check(!o82_color_fw_valid(bundle.data(),bundle.size(),0x42));
        }
        for (unsigned version : {2u,3u}) {
            bundle=snapshot; bundle[7]='0'+version; put_word(bundle,8,version); seal();
            hsic_check(!o82_color_fw_valid(bundle.data(),bundle.size(),0x42));
        }
    }
}
} // namespace
extern "C" int __wrap_main() {
    parser_wire(); composed_mode(); bundle_wire();
    std::cout << "Actual HSIC parser/wire/composed PA: " << hsic_checks
              << " synthetic checks passed; no hardware result\n";
    return 0;
}
