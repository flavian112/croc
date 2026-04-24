// Copyright (c) 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Authors:
// - Flavian Kaufmann
// - Thanu Kanagalingam

// Benchmark: 16-point FFT -- software (Cooley-Tukey) vs hardware accelerator.
//
// Both SW and HW use the same data format and scaling, so outputs are directly comparable:
//   - Data format: each uint32_t = {real[15:0], imag[15:0]}
//   - Scaling: right-shift by 1 after each butterfly stage (4 stages => total factor 1/16)
//
// For a unit impulse input the theoretical DFT output is constant across all bins.

#include "uart.h"
#include "print.h"
#include "util.h"
#include "dsp.h"
#include "config.h"

#define FFT_N 16

// Twiddle factors W_k = exp(-j*2*pi*k/16) for k = 0..7, stored as {cos_k, sin_k} pairs.
// Values are in Q1.15 format (scaled by 32767).
static const int16_t tw16[16] = {
    32767,  0,      30274,  12540,  23170,  23170,  12540,  30274,
    0,      32767,  -12540, 30274,  -23170, 23170,  -30274, 12540,
};

// In-place 16-pt radix-2 DIT FFT on a buffer of packed {real[15:0], imag[15:0]} words.
// Applies a right-shift of 1 after each butterfly to prevent overflow (4 stages => /16).
static void fft_sw_inplace(uint32_t *buf) {
    // Bit-reverse permutation (4-bit index reversal for N=16)
    for (int i = 1, j = 0; i < FFT_N; i++) {
        int bit = FFT_N >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            uint32_t t = buf[i];
            buf[i]     = buf[j];
            buf[j]     = t;
        }
    }
    // Butterfly stages: half-span doubles each stage (1, 2, 4, 8)
    for (int half = 1; half < FFT_N; half <<= 1) {
        int span = half << 1;
        int step = FFT_N / span; // stride through twiddle table
        for (int k = 0; k < FFT_N; k += span) {
            for (int j = 0; j < half; j++) {
                int ti      = (j * step) << 1; // index of {cos, sin} pair in tw16
                int16_t c   = tw16[ti];
                int16_t s   = tw16[ti + 1];
                uint32_t va = buf[k + j];
                uint32_t vb = buf[k + j + half];
                int16_t ar = (int16_t)(va >> 16), ai = (int16_t)va;
                int16_t br = (int16_t)(vb >> 16), bi = (int16_t)vb;
                // Complex twiddle multiply: (c - js)(br + jbi) = c*br+s*bi + j*(c*bi-s*br)
                int32_t wr = ((int32_t)c * br + (int32_t)s * bi) >> 15;
                int32_t wi = ((int32_t)c * bi - (int32_t)s * br) >> 15;
                // Butterfly with >>1 per-stage scaling
                buf[k + j] =
                    ((uint32_t)(uint16_t)(int16_t)((ar + wr) >> 1) << 16) | ((uint16_t)(int16_t)((ai + wi) >> 1));
                buf[k + j + half] =
                    ((uint32_t)(uint16_t)(int16_t)((ar - wr) >> 1) << 16) | ((uint16_t)(int16_t)((ai - wi) >> 1));
            }
        }
    }
}

// Static buffers in SRAM. 2 x 16 x 4 = 128 bytes.
static volatile uint32_t in_buf[FFT_N];
static volatile uint32_t out_buf[FFT_N];

int main() {
    uart_init();

    // Unit impulse: DFT{delta[n]} = 1 for all k.
    // With 1/16 scaling both SW and HW should output the same constant in every bin.
    for (int i = 0; i < FFT_N; i++) in_buf[i] = (i == 0) ? 0x10000000u : 0u;

    // --- Software FFT ---
    for (int i = 0; i < FFT_N; i++) out_buf[i] = in_buf[i];
    uint32_t t0 = (uint32_t)get_mcycle();
    fft_sw_inplace((uint32_t *)out_buf);
    uint32_t sw_cycles = (uint32_t)get_mcycle() - t0;
    uint32_t sw_bin0   = out_buf[0];
    uint32_t sw_bin8   = out_buf[8];

    // --- Hardware FFT ---
    uint32_t t1        = (uint32_t)get_mcycle();
    dsp_run((uint32_t)in_buf, (uint32_t)out_buf);
    uint32_t hw_cycles = (uint32_t)get_mcycle() - t1;

    // --- Results ---
    printf("=== FFT Benchmark (N=16, 20 MHz) ===\n");
    printf("SW: 0x%x cycles  bin[0]=0x%x  bin[8]=0x%x\n", sw_cycles, sw_bin0, sw_bin8);
    printf("HW: 0x%x cycles  bin[0]=0x%x  bin[8]=0x%x\n", hw_cycles, (uint32_t)out_buf[0], (uint32_t)out_buf[8]);
    printf("Speedup: ~0x%x x\n", hw_cycles ? sw_cycles / hw_cycles : 0);

    uart_write_flush();
    return 0;
}
