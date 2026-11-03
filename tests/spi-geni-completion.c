/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <assert.h>
#include <errno.h>
#include <stdio.h>

enum { DMA_TRANS_NOERROR, DMA_TRANS_READ_FAILED };
struct dmaengine_result { int result; unsigned int residue; };
struct spi_message { int status; unsigned int actual_length; };
struct spi_controller { struct spi_message *cur_msg; int dev; };
struct spi_geni_master { int se; };
static struct spi_geni_master master;
static unsigned int completed;
#define spi_controller_get_devdata(spi) ((void)(spi), &master)
#define trace_geni_se_regs(se) ((void)(se))
#define dev_err(dev, ...) ((void)(dev))
#define dev_dbg(dev, ...) ((void)(dev))
static void spi_finalize_current_transfer(struct spi_controller *spi)
{
    assert(spi->cur_msg);
    ++completed;
}
#include "production.h"

int main(void)
{
    struct spi_message message = { .status = -EINPROGRESS };
    struct spi_controller spi = { .cur_msg = &message };
    struct dmaengine_result result = { .result = DMA_TRANS_NOERROR };

    (void)&master;
    for (unsigned int i = 0; i < 3; ++i) {
        spi_gsi_callback_result(&spi, &result);
        assert(message.status == -EINPROGRESS);
        assert(message.actual_length == 0);
        assert(completed == i + 1);
    }
    result.residue = 1;
    spi_gsi_callback_result(&spi, &result);
    assert(message.status == -EIO && completed == 4);
    message.status = -EINPROGRESS;
    result = (struct dmaengine_result){ .result = DMA_TRANS_READ_FAILED };
    spi_gsi_callback_result(&spi, &result);
    assert(message.status == -EIO && completed == 5);
    puts("GENI callback preserves SPI-core ownership; DMA errors and residue fail closed: PASS");
}
