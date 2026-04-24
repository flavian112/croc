// Copyright (c) 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Authors:
// - Flavian Kaufmann
// - Thanu Kanagalingam

// Test: 16-point FFT accelerator correctness.
//
// Feeds a unit impulse at n=0 and checks that all output bins are equal.
//   Input:  in_buf[0] = {real=0x1000, imag=0x0000}  (word = 0x10000000)
//           in_buf[1..31] = 0
//   Theory: DFT{delta[n]} = 1 for all k  =>  all output bins must be equal and nonzero.
//   Exact bin value depends on pipeline scaling; we verify the DFT property directly.

#include "uart.h"
#include "print.h"
#include "util.h"
#include "dsp.h"
#include "config.h"

#define FFT_N       16
#define IMPULSE_VAL 0x10000000u // real=0x1000, imag=0x0000

// Static buffers in SRAM. 2 x 16 x 4 = 128 bytes.
static volatile uint32_t in_buf[FFT_N];
static volatile uint32_t out_buf[FFT_N];

int main() {
    uart_init();
    // --- Write/readback register tests ---
    dsp_set_src(0x10000100);
    CHECK_ASSERT(1, *reg32(DSP_BASE_ADDR, DSP_SRC_ADDR_OFFSET) == 0x10000100);

    dsp_set_dst(0x10000200);
    CHECK_ASSERT(2, *reg32(DSP_BASE_ADDR, DSP_DST_ADDR_OFFSET) == 0x10000200);

    // DSP should be idle after reset (STATUS = 0)
    CHECK_ASSERT(3, *reg32(DSP_BASE_ADDR, DSP_STATUS_OFFSET) == 0);

    // --- Prepare impulse input ---
    for (int i = 0; i < FFT_N; i++) in_buf[i] = (i == 0) ? IMPULSE_VAL : 0;

    // Clear output buffer
    for (int i = 0; i < FFT_N; i++) out_buf[i] = 0;

    // --- Run FFT ---
    dsp_run((uint32_t)in_buf, (uint32_t)out_buf);

    // STATUS.DONE should be set
    CHECK_ASSERT(4, dsp_is_done());
    // STATUS.BUSY should be clear
    CHECK_ASSERT(5, !(*reg32(DSP_BASE_ADDR, DSP_STATUS_OFFSET) & 1));

    // --- Verify output: all 32 bins should be equal (DFT of impulse = constant) ---
    uint32_t expected = out_buf[0];
    CHECK_ASSERT(9, expected != 0); // sanity: FFT must have produced nonzero output
    for (int k = 0; k < FFT_N; k++) {
        CHECK_ASSERT(10 + k, out_buf[k] == expected);
    }

    return 0;
}
