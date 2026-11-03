// SPDX-License-Identifier: GPL-3.0-or-later
// Host-only comparison with the independently retained original C++ decoder.
#include <array>
#include <cassert>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <limits>
#include UKE_TOUCH_REFERENCE_DECODER
extern "C" {
#include "../src/input/nt36532-uke-protocol.h"
}
static std::uint32_t rng=0x76753653U;
static std::uint32_t random_word() {rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
static void word16(std::uint8_t *p,unsigned v) {p[0]=v&255;p[1]=(v>>8)&255;}
static void word32(std::uint8_t *p,std::uint32_t v) {word16(p,v);word16(p+2,v>>16);}
static void compare(const std::array<std::uint8_t,5432> &bytes) {
    const auto original=uke_touch::decode(bytes);
    nvt_uke_frame current{};
    const int result=nvt_uke_decode(bytes.data(),bytes.size(),&current);
    assert(bool(original)==(result==0));
    if(!original)return;
    assert(original->counter==current.counter && original->scan_mode==current.scan_mode);
    for(unsigned node=0;node<2400;node++) {
        unsigned value=unsigned(current.matrix_le[node*2])|(unsigned(current.matrix_le[node*2+1])<<8);
        assert(original->matrix[node]==std::int16_t(value));
    }
}
int main(int argc,char **argv) {
    std::array<std::uint8_t,5432> bytes{};
    unsigned valid=0,mutations=0,captured=0;
    for(unsigned trial=0;trial<10000;trial++) {
        for(auto &byte:bytes)byte=random_word()&255;
        auto *header=bytes.data()+256;
        header[0]=0xa5;header[1]=0x61;
        word32(header+8,0x4bf);word32(header+16,~std::uint32_t(0x4bf));
        header[24]=trial%2?2:4;header[48]=60;header[49]=40;header[56]=3;
        unsigned sum=0;
        for(unsigned offset=0;offset<0x4bf*4;offset+=2)sum+=unsigned(header[20+offset])|(unsigned(header[21+offset])<<8);
        word16(header+4,(-sum)&65535);word16(header+12,(((-sum)&65535)^65535));
        compare(bytes);valid++;
        for(unsigned mutation=0;mutation<8;mutation++) {
            const auto at=random_word()%bytes.size();
            bytes[at]^=std::uint8_t(1U<<(random_word()%8));
            compare(bytes);mutations++;
        }
    }
    uke_touch::Watchdog original;
    unsigned current=0;
    for(unsigned trial=0;trial<10000;trial++) {
        if(trial%31==0)bytes[3]=0;
        else for(unsigned i=0;i<6;i++)bytes[i]=random_word()%2?0xfd:0xfe;
        const auto expected=original.observe(bytes);
        const int result=nvt_uke_watchdog(bytes.data(),bytes.size(),&current);
        assert(result==expected.value_or(0) && original.consecutive==current);
    }
    for(int argument=1;argument<argc;argument++) {
        std::ifstream input(argv[argument],std::ios::binary);
        assert(input);
        while(input.read(reinterpret_cast<char *>(bytes.data()),bytes.size())) {compare(bytes);captured++;}
        assert(input.eof() && !input.gcount());
    }
    std::cout<<"Original C++ vs kernel C: "<<valid<<" generated frames, "<<mutations
        <<" mutations, 10000 watchdog packets, "<<captured<<" retained private frames agree; host only.\n";
}
