// Copyright (c) 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Authors:
// - Flavian Kaufmann
// - Thanu Kanagalingam

// Test: FFT accelerator register interface and fixed-point output correctness.

#include "uart.h"
#include "util.h"
#include "fft.h"
#include "fft_ref.h"

enum {
    FFT_TEST_SRC_ADDR = 0x10000100,
    FFT_TEST_DST_ADDR = 0x10000200,
};

typedef struct {
    const fft_sample_t *input;
} fft_test_vector_t;

static volatile fft_sample_t input_buffer[FFT_N];
static volatile fft_sample_t output_buffer[FFT_N];
static fft_sample_t expected_buffer[FFT_N];

static const fft_sample_t impulse_at_0[FFT_N] = {
    FFT_SAMPLE(0x1000, 0),
};

static const fft_sample_t impulse_at_3[FFT_N] = {
    [3] = FFT_SAMPLE(0x1000, 0),
};

static const fft_sample_t dc_real[FFT_N] = {
    FFT_SAMPLE(0x0400, 0), FFT_SAMPLE(0x0400, 0), FFT_SAMPLE(0x0400, 0), FFT_SAMPLE(0x0400, 0),
    FFT_SAMPLE(0x0400, 0), FFT_SAMPLE(0x0400, 0), FFT_SAMPLE(0x0400, 0), FFT_SAMPLE(0x0400, 0),
    FFT_SAMPLE(0x0400, 0), FFT_SAMPLE(0x0400, 0), FFT_SAMPLE(0x0400, 0), FFT_SAMPLE(0x0400, 0),
    FFT_SAMPLE(0x0400, 0), FFT_SAMPLE(0x0400, 0), FFT_SAMPLE(0x0400, 0), FFT_SAMPLE(0x0400, 0),
};

static const fft_sample_t alternating_real[FFT_N] = {
    FFT_SAMPLE(0x0800, 0), FFT_SAMPLE(-0x0800, 0), FFT_SAMPLE(0x0800, 0), FFT_SAMPLE(-0x0800, 0),
    FFT_SAMPLE(0x0800, 0), FFT_SAMPLE(-0x0800, 0), FFT_SAMPLE(0x0800, 0), FFT_SAMPLE(-0x0800, 0),
    FFT_SAMPLE(0x0800, 0), FFT_SAMPLE(-0x0800, 0), FFT_SAMPLE(0x0800, 0), FFT_SAMPLE(-0x0800, 0),
    FFT_SAMPLE(0x0800, 0), FFT_SAMPLE(-0x0800, 0), FFT_SAMPLE(0x0800, 0), FFT_SAMPLE(-0x0800, 0),
};

static const fft_sample_t mixed_complex[FFT_N] = {
    FFT_SAMPLE(1200, -300), FFT_SAMPLE(-900, 700), FFT_SAMPLE(300, 1100), FFT_SAMPLE(-120, -950),
    FFT_SAMPLE(2047, 0),    FFT_SAMPLE(-2048, 63), FFT_SAMPLE(512, -512), FFT_SAMPLE(-256, 1536),
    FFT_SAMPLE(0, -1700),   FFT_SAMPLE(77, 88),    FFT_SAMPLE(-333, 444), FFT_SAMPLE(999, -111),
    FFT_SAMPLE(-1500, 120), FFT_SAMPLE(640, -321), FFT_SAMPLE(-42, -43),  FFT_SAMPLE(1700, 900),
};

static const fft_sample_t small_values[FFT_N] = {
    FFT_SAMPLE(1, 0),   FFT_SAMPLE(0, 1),   FFT_SAMPLE(-1, 0),  FFT_SAMPLE(0, -1),
    FFT_SAMPLE(2, -2),  FFT_SAMPLE(-2, 2),  FFT_SAMPLE(3, 4),   FFT_SAMPLE(-3, -4),
    FFT_SAMPLE(5, -6),  FFT_SAMPLE(-5, 6),  FFT_SAMPLE(7, 8),   FFT_SAMPLE(-7, -8),
    FFT_SAMPLE(9, -10), FFT_SAMPLE(-9, 10), FFT_SAMPLE(11, 12), FFT_SAMPLE(-11, -12),
};

static const fft_test_vector_t test_vectors[] = {
    {impulse_at_0}, {impulse_at_3}, {dc_real}, {alternating_real}, {mixed_complex}, {small_values}, {impulse_at_0},
};

static void copy_input_vector(const fft_sample_t input[FFT_N]) {
    for (int index = 0; index < FFT_N; index++) {
        input_buffer[index]    = input[index];
        expected_buffer[index] = input[index];
    }
}

static void clear_output_buffer(void) {
    for (int index = 0; index < FFT_N; index++) {
        output_buffer[index] = 0xA5A50000u | (uint32_t)index;
    }
}

static int test_register_readback(void) {
    fft_write_reg(FFT_SRC_ADDR_OFFSET, FFT_TEST_SRC_ADDR);
    CHECK_ASSERT(1, fft_read_reg(FFT_SRC_ADDR_OFFSET) == FFT_TEST_SRC_ADDR);

    fft_write_reg(FFT_DST_ADDR_OFFSET, FFT_TEST_DST_ADDR);
    CHECK_ASSERT(2, fft_read_reg(FFT_DST_ADDR_OFFSET) == FFT_TEST_DST_ADDR);

    CHECK_ASSERT(3, fft_status() == 0);
    return 0;
}

static int run_vector_test(const fft_test_vector_t *vector, int check_base) {
    copy_input_vector(vector->input);
    clear_output_buffer();
    fft_ref_run(expected_buffer);

    fft_run((const fft_sample_t *)input_buffer, (fft_sample_t *)output_buffer);

    CHECK_ASSERT(check_base + 1, fft_done());
    CHECK_ASSERT(check_base + 2, !fft_busy());

    for (int index = 0; index < FFT_N; index++) {
        CHECK_ASSERT(check_base + 10 + index, output_buffer[index] == expected_buffer[index]);
    }

    return 0;
}

int main(void) {
    uart_init();

    CHECK_CALL(test_register_readback());

    for (int index = 0; index < (int)(sizeof(test_vectors) / sizeof(test_vectors[0])); index++) {
        CHECK_CALL(run_vector_test(&test_vectors[index], 100 + 100 * index));
    }

    return 0;
}
