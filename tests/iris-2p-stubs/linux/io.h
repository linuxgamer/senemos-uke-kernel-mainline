// SPDX-License-Identifier: MIT
#ifndef UKE_IRIS_2P_TEST_IO_H
#define UKE_IRIS_2P_TEST_IO_H
#include <cstdint>
using u8 = std::uint8_t;
using u32 = std::uint32_t;
#define __iomem
u32 readl(const volatile void *address);
void writel(u32 value, volatile void *address);
#endif
