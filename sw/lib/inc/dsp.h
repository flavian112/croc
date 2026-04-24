// Copyright (c) 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Authors:
// - Flavian Kaufmann
// - Thanu Kanagalingam

#pragma once

#include <stdint.h>
#include "config.h"
#include "util.h"

// Register offsets from DSP_BASE_ADDR
#define DSP_CTRL_OFFSET     0x00
#define DSP_STATUS_OFFSET   0x04
#define DSP_SRC_ADDR_OFFSET 0x08
#define DSP_DST_ADDR_OFFSET 0x0C
#define DSP_IRQ_CTRL_OFFSET 0x10

// STATUS register bits
#define DSP_STATUS_BUSY_BIT 0
#define DSP_STATUS_DONE_BIT 1

// Set the source address for FFT_N packed complex input samples
static inline void dsp_set_src(uint32_t addr) {
    *reg32(DSP_BASE_ADDR, DSP_SRC_ADDR_OFFSET) = addr;
}

// Set the destination address for FFT_N packed FFT output samples
static inline void dsp_set_dst(uint32_t addr) {
    *reg32(DSP_BASE_ADDR, DSP_DST_ADDR_OFFSET) = addr;
}

// Kick off the FFT — writes START bit, self-clears in hardware
static inline void dsp_start(void) {
    *reg32(DSP_BASE_ADDR, DSP_CTRL_OFFSET) = 1;
}

// Returns non-zero when the last FFT has finished
static inline int dsp_is_done(void) {
    return (*reg32(DSP_BASE_ADDR, DSP_STATUS_OFFSET) >> DSP_STATUS_DONE_BIT) & 1;
}

// Spin-wait until the FFT is done
static inline void dsp_wait_done(void) {
    while (!dsp_is_done());
}

// Convenience: set addresses, start, and wait
static inline void dsp_run(uint32_t src, uint32_t dst) {
    dsp_set_src(src);
    dsp_set_dst(dst);
    dsp_start();
    dsp_wait_done();
}
