// Copyright (c) 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Authors:
// - Flavian Kaufmann
// - Thanu Kanagalingam

// Test: FFT accelerator register interface and fixed-point output correctness.
//
// To test rounding behavior, run with:
//   make test-fft \
//     RISCV_EXTRA_CCFLAGS='-DFFT_REF_USE_ROUNDING=1' \
//     VERILATOR_FLAGS='-GFftUseRounding=1'
// This requires hardware and reference-model options to match.
// Default behavior (UseRounding=0) uses truncation.
//
// To test saturation behavior, run with:
//   make test-fft \
//     RISCV_EXTRA_CCFLAGS='-DFFT_REF_USE_SATURATION=1' \
//     VERILATOR_FLAGS='-GFftUseSaturation=1'
// Default behavior (UseSaturation=0) wraps.
//
// To test inverse FFT behavior, run with:
//   make test-fft \
//     RISCV_EXTRA_CCFLAGS='-DFFT_REF_USE_INVERSE=1' \
//     VERILATOR_FLAGS='-GFftInverse=1'
// Default behavior (Inverse=0) computes forward FFT.

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
static volatile fft_sample_t in_place_buffer[FFT_N];
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
    uint32_t is_inverse = fft_config_inverse();

    CHECK_ASSERT(2, fft_config_length() == FFT_N);
    CHECK_ASSERT(3, fft_config_log2_length() == FFT_SYNTH_LOG2_LENGTH);
    CHECK_ASSERT(4, fft_config_data_width() == FFT_SYNTH_DATA_WIDTH);
    // Keep software reference mode aligned with synthesized hardware direction.
    CHECK_ASSERT(5, is_inverse == (FFT_REF_USE_INVERSE ? 1u : 0u));
    CHECK_ASSERT(6, (scale_mode == FFT_SCALE_NONE) || (scale_mode == FFT_SCALE_EACH_STAGE));
    CHECK_ASSERT(7, fft_config_scale_stages() == (scale_mode == FFT_SCALE_EACH_STAGE));
    CHECK_ASSERT(8, fft_config_bit_reverse());

    uint32_t config = fft_config();
    uint32_t cycles = fft_cycles();
    fft_write_reg(FFT_CONFIG_OFFSET, ~config);
    fft_write_reg(FFT_CYCLES_OFFSET, 0xDEADBEEFu);
    CHECK_ASSERT(9, fft_config() == config);
    CHECK_ASSERT(10, fft_cycles() == cycles);

    fft_write_reg(FFT_SRC_ADDR_OFFSET, FFT_TEST_SRC_ADDR);
    CHECK_ASSERT(11, fft_read_reg(FFT_SRC_ADDR_OFFSET) == FFT_TEST_SRC_ADDR);

    fft_write_reg(FFT_DST_ADDR_OFFSET, FFT_TEST_DST_ADDR);
    CHECK_ASSERT(12, fft_read_reg(FFT_DST_ADDR_OFFSET) == FFT_TEST_DST_ADDR);

    fft_irq_enable(1);
    CHECK_ASSERT(13, fft_read_reg(FFT_IRQ_CTRL_OFFSET) == 1);

    fft_irq_enable(0);
    CHECK_ASSERT(14, fft_read_reg(FFT_IRQ_CTRL_OFFSET) == 0);

    fft_write_reg(FFT_CTRL_OFFSET, 0);
    CHECK_ASSERT(15, fft_status() == 0);
    return 0;
}

static int check_buffer_matches_reference(volatile const fft_sample_t *actual, int check_base) {
    for (int index = 0; index < FFT_N; index++) {
        CHECK_ASSERT(check_base + index, actual[index] == expected_buffer[index]);
    }

    return 0;
}

static int check_output_matches_reference(int check_base) {
    return check_buffer_matches_reference(output_buffer, check_base);
}

static int require_busy_before_done(int check_id) {
    for (int attempt = 0; attempt < 32; attempt++) {
        uint32_t status = fft_status();

        if ((status >> FFT_STATUS_BUSY_BIT) & 1u) {
            return 0;
        }

        CHECK_ASSERT(check_id, !((status >> FFT_STATUS_DONE_BIT) & 1u));
    }

    return check_id;
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
    int half_n = FFT_N / 2;

    clear_input_buffer();

    input_buffer[0] = FFT_SAMPLE(512, 0);
    for (int index = 1; index < half_n; index++) {
        int16_t real                = (int16_t)(700 - 113 * index);
        int16_t imag                = (int16_t)((index & 1) ? (-120 - 80 * index) : (140 + 70 * index));

        input_buffer[index]         = fft_pack(real, imag);
        input_buffer[FFT_N - index] = fft_pack(real, (int16_t)-imag);
    }

    // Nyquist bin for even-length FFT must be purely real for this construction.
    input_buffer[half_n] = FFT_SAMPLE(-1024, 0);

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

static int test_clear_done_idempotent(void) {
    clear_input_buffer();
    input_buffer[0] = FFT_SAMPLE(0x0200, 0x0100);
    CHECK_CALL(run_prepared_vector(4100, 0));

    CHECK_ASSERT(4129, fft_done());
    fft_clear_done();
    CHECK_ASSERT(4130, !fft_done());
    fft_clear_done();
    CHECK_ASSERT(4131, !fft_done());
    CHECK_ASSERT(4132, !fft_busy());
    CHECK_ASSERT(4133, fft_cycles() > 0);

    return 0;
}

static int test_back_to_back_runs_without_done_clear(void) {
    for (int vector = 0; vector < 4; vector++) {
        clear_input_buffer();
        input_buffer[vector % FFT_N] = fft_pack((int16_t)(0x0200 + 0x0100 * vector), (int16_t)(-0x0080 * vector));

        clear_output_buffer();
        prepare_expected_buffer();

        fft_set_src((const fft_sample_t *)input_buffer);
        fft_set_dst((fft_sample_t *)output_buffer);
        fft_start();

        // A new START must clear stale DONE from the previous run.
        CHECK_ASSERT(4200 + 100 * vector, !fft_done() || fft_busy());

        fft_wait_done();
        CHECK_ASSERT(4201 + 100 * vector, fft_done());
        CHECK_ASSERT(4202 + 100 * vector, !fft_busy());
        CHECK_CALL(check_output_matches_reference(4210 + 100 * vector));
    }

    return 0;
}

static int test_start_write_while_busy(void) {
    clear_input_buffer();
    input_buffer[0]         = FFT_SAMPLE(0x0400, 0);
    input_buffer[FFT_N / 2] = FFT_SAMPLE(-0x0200, 0x0100);

    clear_output_buffer();
    prepare_expected_buffer();

    fft_set_src((const fft_sample_t *)input_buffer);
    fft_set_dst((fft_sample_t *)output_buffer);
    fft_start();
    CHECK_CALL(require_busy_before_done(4600));
    fft_start();
    fft_wait_done();

    CHECK_ASSERT(4601, fft_done());
    CHECK_ASSERT(4602, !fft_busy());
    return check_output_matches_reference(4610);
}

static int test_irq_control_write_during_run(void) {
    clear_input_buffer();
    input_buffer[0]         = FFT_SAMPLE(0x0100, 0x0200);
    input_buffer[1 % FFT_N] = FFT_SAMPLE(-0x0080, 0x0040);

    clear_output_buffer();
    prepare_expected_buffer();

    fft_irq_enable(0);
    fft_set_src((const fft_sample_t *)input_buffer);
    fft_set_dst((fft_sample_t *)output_buffer);
    fft_start();
    fft_irq_enable(1);
    fft_wait_done();

    CHECK_ASSERT(4701, fft_read_reg(FFT_IRQ_CTRL_OFFSET) == 1);
    CHECK_ASSERT(4702, fft_done());
    CHECK_ASSERT(4703, !fft_busy());
    CHECK_CALL(check_output_matches_reference(4710));

    fft_irq_enable(0);
    CHECK_ASSERT(4730, fft_read_reg(FFT_IRQ_CTRL_OFFSET) == 0);
    return 0;
}

static int test_in_place_buffer(void) {
    clear_input_buffer();

    for (int index = 0; index < FFT_N; index++) {
        input_buffer[index]    = fft_pack((int16_t)(0x0180 - 0x20 * index), (int16_t)((index & 1) ? 0x0100 : -0x0080));
        in_place_buffer[index] = input_buffer[index];
    }

    prepare_expected_buffer();
    fft_run((const fft_sample_t *)in_place_buffer, (fft_sample_t *)in_place_buffer);

    CHECK_ASSERT(4801, fft_done());
    CHECK_ASSERT(4802, !fft_busy());
    return check_buffer_matches_reference(in_place_buffer, 4810);
}

static int test_forward_inverse_relationship(void) {
    // Test mathematical consistency between forward and inverse FFT.
    // Forward FFT: impulse at 0 -> constant-like spectrum
    // Inverse FFT: DC (constant) -> impulse-like time domain
    // This test passes on forward or inverse accelerators by testing known properties.

    if (FFT_REF_USE_INVERSE) {
        // For inverse FFT: input all ones should produce scaled impulse at bin 0
        for (int index = 0; index < FFT_N; index++) {
            input_buffer[index] = FFT_SAMPLE(4096, 0); // DC input
        }

        clear_output_buffer();
        prepare_expected_buffer();

        fft_run((const fft_sample_t *)input_buffer, (fft_sample_t *)output_buffer);

        CHECK_ASSERT(4001, fft_done());
        CHECK_ASSERT(4002, !fft_busy());

        // After inverse FFT, result should match reference model
        return check_output_matches_reference(4010);
    } else {
        // For forward FFT: impulse at 0 should produce roughly constant spectrum
        clear_input_buffer();
        input_buffer[0] = FFT_SAMPLE(4096, 0); // Impulse at bin 0

        clear_output_buffer();
        prepare_expected_buffer();

        fft_run((const fft_sample_t *)input_buffer, (fft_sample_t *)output_buffer);

        CHECK_ASSERT(4001, fft_done());
        CHECK_ASSERT(4002, !fft_busy());

        // After forward FFT, result should match reference model
        return check_output_matches_reference(4010);
    }
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
    CHECK_CALL(test_clear_done_idempotent());
    CHECK_CALL(test_back_to_back_runs_without_done_clear());
    CHECK_CALL(test_start_write_while_busy());
    CHECK_CALL(test_irq_control_write_during_run());
    CHECK_CALL(test_in_place_buffer());
    CHECK_CALL(test_forward_inverse_relationship());

    return 0;
}
