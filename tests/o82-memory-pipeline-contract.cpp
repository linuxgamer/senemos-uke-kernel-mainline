// SPDX-License-Identifier: MIT
// Actual converter -> private semantic payload -> kernel validator, synthetic only.
#include "o82-memory-color.h"
#include "o82-memory-format.h"

#include <array>
#include <cassert>
#include <cstdio>

namespace {
using Payload = std::array<unsigned char,O82_MEMORY_BYTES>;
void put(Payload &p,unsigned at,unsigned value) {
    for(unsigned i=0;i<4;i++)p.at(at+i)=static_cast<unsigned char>(value>>(8*i));
}
void region(Payload &payload,unsigned index,const o82::MemoryColorData &v) {
    const std::array<unsigned,8> words{v.adjust_p0,v.adjust_p1,v.adjust_p2,v.blend_gain,
        unsigned(v.saturation_hold)|(unsigned(v.value_hold)<<2),v.hue_region,v.saturation_region,v.value_region};
    for(unsigned i=0;i<words.size();i++)put(payload,16+32*index+4*i,words[i]);
}
}
int main() {
    assert(std::fegetround()==FE_TONEAREST);
    assert(o82_memory_blend(8,8,11)==3050403);
    assert(2147483648U/(8*8*11)==3050402);
    assert(!o82_memory_blend(0,8,8)&&!o82_memory_blend(8,256,8)&&!o82_memory_inverse(0));
    unsigned long long blend_cases=0,integer_differences=0;
    for(unsigned h=8;h<=1536;h++)for(unsigned s=8;s<=255;s++)for(unsigned v=s;v<=255;v++) {
        // Hardware floating-point is independent of the kernel's integer IEEE
        // emulation. Preserve both binary32 instruction boundaries explicitly.
        const unsigned product=h*s*v;
        volatile float denominator=static_cast<float>(product);
        volatile float result=2147483648.0f/denominator;
        const auto expected=static_cast<unsigned>(result);
        assert(o82_memory_blend(h,s,v)==expected);
        integer_differences+=expected!=2147483648U/product;
        blend_cases++;
    }
    assert(integer_differences);
    unsigned bridge_cases=0;
    for(int h=0;h<=360;h++)for(unsigned s=0;s<=100;s++) {
        o82::MemoryColorInput in;
        in.hue_extent=h;in.hue_adjustment=(h&1)?180:-180;
        in.saturation_extent=s;in.value_extent=100-s;
        in.saturation_adjustment=-100;in.value_adjustment=100;
        in.saturation_minimum=12.5f;in.saturation_maximum=87.25f;
        in.value_minimum=3.125f;in.value_maximum=98.5f;
        in.hue_minimum=-180;in.hue_maximum=180;
        in.saturation_hold_control=s%4;in.value_hold_control=(s+1)%4;
        o82::MemoryColorData out;
        assert(o82::compile_memory_color(in,out)==o82::MemoryColorError::none);
        Payload payload{};put(payload,0,1);put(payload,8,1);region(payload,0,out);
        assert(o82_memory_valid(payload.data(),payload.size()));
        bridge_cases++;
    }
    o82::MemoryColorData out;
    assert(o82::compile_memory_color({},out)==o82::MemoryColorError::none);
    for(unsigned mask=0;mask<8;mask++)for(unsigned flags=0;flags<64;flags++) {
        Payload p{};put(p,0,mask);put(p,4,flags);put(p,8,1);
        for(unsigned i=0;i<3;i++)if(mask&(1U<<i))region(p,i,out);
        assert(o82_memory_valid(p.data(),p.size()));
        for(unsigned byte=0;byte<16;byte++) {
            auto bad=p;bad[byte]^=0x80;
            assert(!o82_memory_valid(bad.data(),bad.size()));
        }
        bridge_cases++;
    }
    assert(!o82_memory_valid(nullptr,112));
    Payload neutral{};put(neutral,8,1);
    assert(o82_memory_valid(neutral.data(),neutral.size()));
    assert(!o82_memory_valid(neutral.data(),neutral.size()-1));
    std::printf("Memory semantic bridge: %u actual converter/payload/validator cases passed, explicit inactive regions and protection-only states included; synthetic only\n",bridge_cases);
    std::printf("Kernel integer blend: %llu raw-dimension cases match separate binary32 operations; plain integer division differs in %llu cases\n",blend_cases,integer_differences);
}
