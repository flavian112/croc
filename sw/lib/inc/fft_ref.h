// Copyright (c) 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Authors:
// - Flavian Kaufmann
// - Thanu Kanagalingam

#pragma once

#include <stdint.h>
#include "fft.h"

/**
 * @file fft_ref.h
 * @brief Small fixed-point FFT reference model for tests and benchmarks.
 *
 * This model intentionally mirrors the accelerator's fixed-point arithmetic:
 * 16-point radix-2 DIT FFT, Q1.15 twiddles, and one arithmetic right shift per
 * butterfly stage. It is not a generic FFT library.
 */

typedef struct {
    int16_t real;
    int16_t imag;
} fft_ref_twiddle_t;

// W_k = exp(-j*2*pi*k/16), represented as {cos(k), sin(k)} in Q1.15.
static const fft_ref_twiddle_t fft_ref_twiddles[FFT_N / 2] = {
    {32767,  0    },
    {30274,  12540},
    {23170,  23170},
    {12540,  30274},
    {0,      32767},
    {-12540, 30274},
    {-23170, 23170},
    {-30274, 12540},
};

static inline void fft_ref_swap(fft_sample_t *a, fft_sample_t *b) {
    fft_sample_t tmp = *a;
    *a               = *b;
    *b               = tmp;
}

static inline void fft_ref_bit_reverse(fft_sample_t samples[FFT_N]) {
    int reversed = 0;

    for (int index = 1; index < FFT_N; index++) {
        int bit = FFT_N >> 1;

        while (reversed & bit) {
            reversed ^= bit;
            bit >>= 1;
        }
        reversed ^= bit;

        if (index < reversed) {
            fft_ref_swap(&samples[index], &samples[reversed]);
        }
    }
}

static inline fft_sample_t fft_ref_butterfly_product(fft_sample_t sample, fft_ref_twiddle_t twiddle) {
    int16_t sample_real  = fft_real(sample);
    int16_t sample_imag  = fft_imag(sample);

    // (c - j*s) * (real + j*imag), with c/s stored in Q1.15.
    int32_t product_real = ((int32_t)twiddle.real * sample_real + (int32_t)twiddle.imag * sample_imag) >> 15;
    int32_t product_imag = ((int32_t)twiddle.real * sample_imag - (int32_t)twiddle.imag * sample_real) >> 15;

    return fft_pack((int16_t)product_real, (int16_t)product_imag);
}

static inline void fft_ref_apply_stage(fft_sample_t samples[FFT_N], int half_span) {
    int span           = half_span << 1;
    int twiddle_stride = FFT_N / span;

    for (int base = 0; base < FFT_N; base += span) {
        for (int offset = 0; offset < half_span; offset++) {
            int lower_index    = base + offset;
            int upper_index    = lower_index + half_span;

            fft_sample_t lower = samples[lower_index];
            fft_sample_t upper =
                fft_ref_butterfly_product(samples[upper_index], fft_ref_twiddles[offset * twiddle_stride]);

            int16_t lower_real = fft_real(lower);
            int16_t lower_imag = fft_imag(lower);
            int16_t upper_real = fft_real(upper);
            int16_t upper_imag = fft_imag(upper);

            samples[lower_index] =
                fft_pack((int16_t)((lower_real + upper_real) >> 1), (int16_t)((lower_imag + upper_imag) >> 1));
            samples[upper_index] =
                fft_pack((int16_t)((lower_real - upper_real) >> 1), (int16_t)((lower_imag - upper_imag) >> 1));
        }
    }
}

static inline void fft_ref_run(fft_sample_t samples[FFT_N]) {
    fft_ref_bit_reverse(samples);

    for (int half_span = 1; half_span < FFT_N; half_span <<= 1) {
        fft_ref_apply_stage(samples, half_span);
    }
}
