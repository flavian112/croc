// Copyright (c) 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Authors:
// - Flavian Kaufmann
// - Thanu Kanagalingam

// Test: FFT accelerator register interface and fixed-point output correctness.
//
// To test rounding behavior, compile with:
//   CFLAGS="-DFFT_REF_USE_ROUNDING=1" make test-fft
// This requires the hardware to also be synthesized with UseRounding parameter
// set to 1 on the fft_core instantiation (e.g., in top-level module parameters).
// Default behavior (UseRounding=0) uses truncation.
//
// To test saturation behavior, compile with:
//   CFLAGS="-DFFT_REF_USE_SATURATION=1" make test-fft
// This requires the hardware to also be synthesized with UseSaturation parameter
// set to 1 on the fft_core instantiation. Default behavior (UseSaturation=0) wraps.

#include "uart.h"
#include "util.h"
#include "fft.h"
#include "fft_ref.h"

enum {
    FFT_TEST_SRC_ADDR = 0x10000100,
    FFT_TEST_DST_ADDR = 0x10000200,
};

static volatile fft_sample_t input_buffer[FFT_N];
static volatile fft_sample_t output_buffer[FFT_N];
static fft_sample_t expected_buffer[FFT_N];

static void clear_input_buffer(void) {
    for (int index = 0; index < FFT_N; index++) {
        input_buffer[index] = FFT_SAMPLE(0, 0);
    }
}

static void clear_output_buffer(void) {
    for (int index = 0; index < FFT_N; index++) {
        output_buffer[index] = 0xA5A50000u | (uint32_t)index;
    }
}

static void prepare_expected_buffer(void) {
    for (int index = 0; index < FFT_N; index++) {
        expected_buffer[index] = input_buffer[index];
    }

    fft_ref_run(expected_buffer);
}

static int test_register_readback(void) {
    uint32_t scale_mode = fft_config_scale_mode();

    CHECK_ASSERT(2, fft_config_length() == FFT_N);
    CHECK_ASSERT(3, fft_config_log2_length() == 4);
    CHECK_ASSERT(4, fft_config_data_width() == 16);
    CHECK_ASSERT(5, !fft_config_inverse());
    CHECK_ASSERT(6, (scale_mode == FFT_SCALE_NONE) || (scale_mode == FFT_SCALE_EACH_STAGE));
    CHECK_ASSERT(7, fft_config_scale_stages() == (scale_mode == FFT_SCALE_EACH_STAGE));
    CHECK_ASSERT(8, fft_config_bit_reverse());

    fft_write_reg(FFT_SRC_ADDR_OFFSET, FFT_TEST_SRC_ADDR);
    CHECK_ASSERT(10, fft_read_reg(FFT_SRC_ADDR_OFFSET) == FFT_TEST_SRC_ADDR);

    fft_write_reg(FFT_DST_ADDR_OFFSET, FFT_TEST_DST_ADDR);
    CHECK_ASSERT(11, fft_read_reg(FFT_DST_ADDR_OFFSET) == FFT_TEST_DST_ADDR);

    fft_irq_enable(1);
    CHECK_ASSERT(12, fft_read_reg(FFT_IRQ_CTRL_OFFSET) == 1);

    fft_irq_enable(0);
    CHECK_ASSERT(13, fft_read_reg(FFT_IRQ_CTRL_OFFSET) == 0);

    CHECK_ASSERT(14, fft_status() == 0);
    return 0;
}

static int check_output_matches_reference(int check_base) {
    for (int index = 0; index < FFT_N; index++) {
        CHECK_ASSERT(check_base + index, output_buffer[index] == expected_buffer[index]);
    }

    return 0;
}

static int run_prepared_vector(int check_base, int clear_done_after_run) {
    clear_output_buffer();
    prepare_expected_buffer();

    fft_run((const fft_sample_t *)input_buffer, (fft_sample_t *)output_buffer);

    CHECK_ASSERT(check_base + 1, fft_done());
    CHECK_ASSERT(check_base + 2, !fft_busy());
    CHECK_ASSERT(check_base + 3, fft_cycles() > 0);

    if (clear_done_after_run) {
        fft_clear_done();
        CHECK_ASSERT(check_base + 4, !fft_done());
    }

    return check_output_matches_reference(check_base + 10);
}

static int test_all_impulses(void) {
    for (int impulse_index = 0; impulse_index < FFT_N; impulse_index++) {
        clear_input_buffer();
        input_buffer[impulse_index] = FFT_SAMPLE(0x1000, 0);
        CHECK_CALL(run_prepared_vector(100 + 100 * impulse_index, 1));
    }

    return 0;
}

static int test_dc_vectors(void) {
    clear_input_buffer();
    for (int index = 0; index < FFT_N; index++) {
        input_buffer[index] = FFT_SAMPLE(0x0400, 0);
    }
    CHECK_CALL(run_prepared_vector(2000, 1));

    clear_input_buffer();
    for (int index = 0; index < FFT_N; index++) {
        input_buffer[index] = FFT_SAMPLE(0, -0x0300);
    }
    CHECK_CALL(run_prepared_vector(2100, 1));

    return 0;
}

static int test_nyquist_vector(void) {
    for (int index = 0; index < FFT_N; index++) {
        input_buffer[index] = (index & 1) ? FFT_SAMPLE(-0x0800, 0) : FFT_SAMPLE(0x0800, 0);
    }

    return run_prepared_vector(2200, 1);
}

static int test_conjugate_symmetric_input(void) {
    clear_input_buffer();

    input_buffer[0] = FFT_SAMPLE(512, 0);
    input_buffer[1] = FFT_SAMPLE(700, -120);
    input_buffer[2] = FFT_SAMPLE(-300, 450);
    input_buffer[3] = FFT_SAMPLE(128, 900);
    input_buffer[4] = FFT_SAMPLE(-1024, 0);
    input_buffer[5] = FFT_SAMPLE(64, -700);
    input_buffer[6] = FFT_SAMPLE(333, 111);
    input_buffer[7] = FFT_SAMPLE(-222, 555);
    input_buffer[8] = FFT_SAMPLE(-256, 0);

    for (int index = 1; index < FFT_N / 2; index++) {
        input_buffer[FFT_N - index] = fft_pack(fft_real(input_buffer[index]), -fft_imag(input_buffer[index]));
    }

    return run_prepared_vector(2300, 1);
}

static uint32_t xorshift32(uint32_t *state) {
    uint32_t value = *state;

    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
    *state = value;
    return value;
}

static int test_pseudo_random_vectors(void) {
    uint32_t state = 0x13579BDFu;

    for (int vector = 0; vector < 4; vector++) {
        for (int index = 0; index < FFT_N; index++) {
            uint32_t real       = xorshift32(&state);
            uint32_t imag       = xorshift32(&state);

            // Keep amplitudes moderate so today's wraparound arithmetic is not
            // the main thing under test; saturation experiments come later.
            input_buffer[index] = fft_pack((int16_t)((real & 0x0FFFu) - 2048), (int16_t)((imag & 0x0FFFu) - 2048));
        }

        CHECK_CALL(run_prepared_vector(3000 + 100 * vector, 1));
    }

    return 0;
}

static int test_edge_value_vector(void) {
    static const int16_t values[] = {
        32767, -32768, 16384, -16384, 8192, -8192, 1, -1,
    };

    for (int index = 0; index < FFT_N; index++) {
        input_buffer[index] = fft_pack(values[index % 8], values[(index + 3) % 8]);
    }

    return run_prepared_vector(3400, 1);
}

static int test_done_cleared_by_new_start(void) {
    clear_input_buffer();
    input_buffer[0] = FFT_SAMPLE(0x1000, 0);
    CHECK_CALL(run_prepared_vector(3500, 0));
    CHECK_ASSERT(3529, fft_done());

    clear_input_buffer();
    input_buffer[1] = FFT_SAMPLE(0x1000, 0);
    CHECK_CALL(run_prepared_vector(3600, 1));

    return 0;
}

static int test_max_positive_inputs(void) {
    // Test with maximum positive values that may trigger saturation during
    // butterfly additions in early stages when saturation is enabled.
    for (int index = 0; index < FFT_N; index++) {
        input_buffer[index] = FFT_SAMPLE(32767, 32767);
    }

    return run_prepared_vector(3700, 1);
}

static int test_max_negative_inputs(void) {
    // Test with maximum negative values.
    for (int index = 0; index < FFT_N; index++) {
        input_buffer[index] = FFT_SAMPLE(-32768, -32768);
    }

    return run_prepared_vector(3800, 1);
}

static int test_mixed_extreme_inputs(void) {
    // Alternating max positive and max negative to stress addition/subtraction.
    for (int index = 0; index < FFT_N; index++) {
        if (index & 1) {
            input_buffer[index] = FFT_SAMPLE(32767, -32768);
        } else {
            input_buffer[index] = FFT_SAMPLE(-32768, 32767);
        }
    }

    return run_prepared_vector(3900, 1);
}

int main(void) {
    uart_init();

    CHECK_CALL(test_register_readback());
    CHECK_CALL(test_all_impulses());
    CHECK_CALL(test_dc_vectors());
    CHECK_CALL(test_nyquist_vector());
    CHECK_CALL(test_conjugate_symmetric_input());
    CHECK_CALL(test_pseudo_random_vectors());
    CHECK_CALL(test_edge_value_vector());
    CHECK_CALL(test_done_cleared_by_new_start());
    CHECK_CALL(test_max_positive_inputs());
    CHECK_CALL(test_max_negative_inputs());
    CHECK_CALL(test_mixed_extreme_inputs());

    return 0;
}
