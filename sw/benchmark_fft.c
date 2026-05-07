// Copyright (c) 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Authors:
// - Flavian Kaufmann
// - Thanu Kanagalingam

// Benchmark: compare the reference software FFT against the hardware accelerator.

#include "uart.h"
#include "print.h"
#include "util.h"
#include "fft.h"
#include "fft_ref.h"

typedef struct {
    uint32_t cycles;
    fft_sample_t bin0;
    fft_sample_t bin8;
} fft_benchmark_result_t;

static volatile fft_sample_t input_buffer[FFT_N];
static volatile fft_sample_t output_buffer[FFT_N];
static fft_sample_t software_buffer[FFT_N];

static void prepare_impulse_input(void) {
    for (int index = 0; index < FFT_N; index++) {
        input_buffer[index] = (index == 0) ? fft_pack(0x1000, 0) : 0u;
    }
}

static void copy_input_to_software_buffer(void) {
    for (int index = 0; index < FFT_N; index++) {
        software_buffer[index] = input_buffer[index];
    }
}

static fft_benchmark_result_t benchmark_software_fft(void) {
    copy_input_to_software_buffer();

    uint32_t start_cycles = (uint32_t)get_mcycle();
    fft_ref_run(software_buffer);

    fft_benchmark_result_t result = {
        .cycles = (uint32_t)get_mcycle() - start_cycles,
        .bin0   = software_buffer[0],
        .bin8   = software_buffer[8],
    };
    return result;
}

static fft_benchmark_result_t benchmark_hardware_fft(void) {
    uint32_t start_cycles = (uint32_t)get_mcycle();
    fft_run((const fft_sample_t *)input_buffer, (fft_sample_t *)output_buffer);

    fft_benchmark_result_t result = {
        .cycles = (uint32_t)get_mcycle() - start_cycles,
        .bin0   = output_buffer[0],
        .bin8   = output_buffer[8],
    };
    return result;
}

static void print_software_result(fft_benchmark_result_t result) {
    printf("SW: 0x%x cycles  bin[0]=0x%x  bin[8]=0x%x\n", result.cycles, result.bin0, result.bin8);
}

static void print_hardware_result(fft_benchmark_result_t result) {
    printf("HW: 0x%x cycles  bin[0]=0x%x  bin[8]=0x%x\n", result.cycles, result.bin0, result.bin8);
}

int main(void) {
    uart_init();
    prepare_impulse_input();

    fft_benchmark_result_t software = benchmark_software_fft();
    fft_benchmark_result_t hardware = benchmark_hardware_fft();

    printf("=== FFT Benchmark (N=0x%x, 20 MHz) ===\n", FFT_N);
    print_software_result(software);
    print_hardware_result(hardware);
    printf("Speedup: ~0x%x x\n", hardware.cycles ? software.cycles / hardware.cycles : 0);

    uart_write_flush();
    return 0;
}
