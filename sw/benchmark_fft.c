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
    uint32_t software_visible_cycles;
    uint32_t accelerator_cycles;
    uint32_t transfer_overhead_cycles;
    fft_sample_t bin0;
    fft_sample_t bin_mid;
} fft_benchmark_result_t;

typedef struct {
    uint32_t min;
    uint32_t median;
    uint32_t max;
} fft_benchmark_stats_t;

typedef struct {
    fft_benchmark_stats_t software_visible_cycles;
    fft_benchmark_stats_t accelerator_cycles;
    fft_benchmark_stats_t transfer_overhead_cycles;
    fft_sample_t bin0;
    fft_sample_t bin_mid;
} fft_benchmark_summary_t;

typedef struct {
    const char *name;
    const char *csv_name;
    uint32_t seed;
    void (*prepare_input)(uint32_t seed);
} fft_benchmark_case_t;

enum {
    FFT_BENCH_RUNS = 5,
};

static volatile fft_sample_t input_buffer[FFT_N];
static volatile fft_sample_t output_buffer[FFT_N];
static volatile fft_sample_t inplace_buffer[FFT_N];
static fft_sample_t software_buffer[FFT_N];

static void print_str(const char *str) {
    while (*str) {
        putchar(*str++);
    }
}

static void prepare_impulse_input(uint32_t seed) {
    (void)seed;
    for (int index = 0; index < FFT_N; index++) {
        input_buffer[index] = (index == 0) ? fft_pack(0x1000, 0) : 0u;
    }
}

static uint32_t xorshift32(uint32_t *state) {
    uint32_t value = *state;

    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
    *state = value;
    return value;
}

static void prepare_seeded_random_input(uint32_t seed) {
    uint32_t state = seed;

    for (int index = 0; index < FFT_N; index++) {
        uint32_t real       = xorshift32(&state);
        uint32_t imag       = xorshift32(&state);
        input_buffer[index] = fft_pack((int16_t)((real & 0x0FFFu) - 2048), (int16_t)((imag & 0x0FFFu) - 2048));
    }
}

static void copy_input_to_software_buffer(void) {
    for (int index = 0; index < FFT_N; index++) {
        software_buffer[index] = input_buffer[index];
    }
}

static void copy_input_to_inplace_buffer(void) {
    for (int index = 0; index < FFT_N; index++) {
        inplace_buffer[index] = input_buffer[index];
    }
}

static fft_benchmark_result_t benchmark_software_fft(void) {
    copy_input_to_software_buffer();

    uint32_t start_cycles = (uint32_t)get_mcycle();
    fft_ref_run(software_buffer);

    fft_benchmark_result_t result = {
        .software_visible_cycles  = (uint32_t)get_mcycle() - start_cycles,
        .accelerator_cycles       = 0,
        .transfer_overhead_cycles = 0,
        .bin0                     = software_buffer[0],
        .bin_mid                  = software_buffer[FFT_N / 2],
    };
    return result;
}

static fft_benchmark_result_t benchmark_hardware_fft(void) {
    uint32_t start_cycles = (uint32_t)get_mcycle();
    fft_run((const fft_sample_t *)input_buffer, (fft_sample_t *)output_buffer);

    uint32_t total_cycles         = (uint32_t)get_mcycle() - start_cycles;
    uint32_t accel_cycles         = fft_cycles();
    uint32_t transfer_overhead    = (total_cycles > accel_cycles) ? (total_cycles - accel_cycles) : 0;

    fft_benchmark_result_t result = {
        .software_visible_cycles  = total_cycles,
        .accelerator_cycles       = accel_cycles,
        .transfer_overhead_cycles = transfer_overhead,
        .bin0                     = output_buffer[0],
        .bin_mid                  = output_buffer[FFT_N / 2],
    };
    return result;
}

static fft_benchmark_result_t benchmark_hardware_fft_inplace(void) {
    copy_input_to_inplace_buffer();

    uint32_t start_cycles = (uint32_t)get_mcycle();
    fft_run((const fft_sample_t *)inplace_buffer, (fft_sample_t *)inplace_buffer);

    uint32_t total_cycles         = (uint32_t)get_mcycle() - start_cycles;
    uint32_t accel_cycles         = fft_cycles();
    uint32_t transfer_overhead    = (total_cycles > accel_cycles) ? (total_cycles - accel_cycles) : 0;

    fft_benchmark_result_t result = {
        .software_visible_cycles  = total_cycles,
        .accelerator_cycles       = accel_cycles,
        .transfer_overhead_cycles = transfer_overhead,
        .bin0                     = inplace_buffer[0],
        .bin_mid                  = inplace_buffer[FFT_N / 2],
    };
    return result;
}

static int outputs_match(const fft_sample_t *lhs, const volatile fft_sample_t *rhs) {
    for (int index = 0; index < FFT_N; index++) {
        if (lhs[index] != rhs[index]) {
            return 0;
        }
    }

    return 1;
}

static void sort_samples(uint32_t samples[FFT_BENCH_RUNS]) {
    for (int index = 1; index < FFT_BENCH_RUNS; index++) {
        uint32_t value = samples[index];
        int insert_at  = index;

        while (insert_at > 0 && samples[insert_at - 1] > value) {
            samples[insert_at] = samples[insert_at - 1];
            insert_at--;
        }
        samples[insert_at] = value;
    }
}

static void summarize_samples(const uint32_t samples[FFT_BENCH_RUNS], fft_benchmark_stats_t *stats) {
    uint32_t sorted[FFT_BENCH_RUNS];

    for (int index = 0; index < FFT_BENCH_RUNS; index++) {
        sorted[index] = samples[index];
    }
    sort_samples(sorted);

    stats->min    = sorted[0];
    stats->median = sorted[FFT_BENCH_RUNS / 2];
    stats->max    = sorted[FFT_BENCH_RUNS - 1];
}

static void summarize_results(const fft_benchmark_result_t samples[FFT_BENCH_RUNS], fft_benchmark_summary_t *summary) {
    uint32_t software_visible_cycles[FFT_BENCH_RUNS];
    uint32_t accelerator_cycles[FFT_BENCH_RUNS];
    uint32_t transfer_overhead_cycles[FFT_BENCH_RUNS];

    for (int index = 0; index < FFT_BENCH_RUNS; index++) {
        software_visible_cycles[index]  = samples[index].software_visible_cycles;
        accelerator_cycles[index]       = samples[index].accelerator_cycles;
        transfer_overhead_cycles[index] = samples[index].transfer_overhead_cycles;
    }

    summarize_samples(software_visible_cycles, &summary->software_visible_cycles);
    summarize_samples(accelerator_cycles, &summary->accelerator_cycles);
    summarize_samples(transfer_overhead_cycles, &summary->transfer_overhead_cycles);
    summary->bin0    = samples[0].bin0;
    summary->bin_mid = samples[0].bin_mid;
}

static void print_summary_line(const char *label, const fft_benchmark_summary_t *summary) {
    print_str(label);
    printf(" vis=0x%x/0x%x/0x%x", summary->software_visible_cycles.min,
           summary->software_visible_cycles.median, summary->software_visible_cycles.max);
    if (summary->accelerator_cycles.max > 0u) {
        printf(" acc=0x%x/0x%x/0x%x ovh=0x%x/0x%x/0x%x",
               summary->accelerator_cycles.min, summary->accelerator_cycles.median, summary->accelerator_cycles.max,
               summary->transfer_overhead_cycles.min, summary->transfer_overhead_cycles.median,
               summary->transfer_overhead_cycles.max);
    } else {
        printf(" bin0=0x%x binN=0x%x", summary->bin0, summary->bin_mid);
    }
    printf("\n");
}

static void print_csv_line(const char *case_name, const char *mode_name, uint32_t seed,
                           const fft_benchmark_summary_t *summary) {
    print_str("BENCH_CSV,");
    print_str(case_name);
    putchar(',');
    print_str(mode_name);
    printf(",0x%x,0x%x,0x%x,0x%x,0x%x,0x%x,0x%x,0x%x,0x%x,0x%x,0x%x,0x%x,0x%x\n", FFT_BENCH_RUNS, seed,
           summary->software_visible_cycles.min, summary->software_visible_cycles.median,
           summary->software_visible_cycles.max, summary->accelerator_cycles.min, summary->accelerator_cycles.median,
           summary->accelerator_cycles.max, summary->transfer_overhead_cycles.min,
           summary->transfer_overhead_cycles.median, summary->transfer_overhead_cycles.max, summary->bin0,
           summary->bin_mid);
}

static int run_benchmark_case(const fft_benchmark_case_t *benchmark_case) {
    fft_benchmark_result_t software_runs[FFT_BENCH_RUNS];
    fft_benchmark_result_t hardware_out_of_place_runs[FFT_BENCH_RUNS];
    fft_benchmark_result_t hardware_in_place_runs[FFT_BENCH_RUNS];

    for (int run = 0; run < FFT_BENCH_RUNS; run++) {
        benchmark_case->prepare_input(benchmark_case->seed);
        software_runs[run] = benchmark_software_fft();

        benchmark_case->prepare_input(benchmark_case->seed);
        hardware_out_of_place_runs[run] = benchmark_hardware_fft();
        if (!outputs_match(software_buffer, output_buffer)) {
            print_str("Benchmark mismatch: case=");
            print_str(benchmark_case->name);
            printf(" mode=hw-out-of-place run=0x%x\n", run);
            return 1;
        }

        benchmark_case->prepare_input(benchmark_case->seed);
        hardware_in_place_runs[run] = benchmark_hardware_fft_inplace();
        if (!outputs_match(software_buffer, inplace_buffer)) {
            print_str("Benchmark mismatch: case=");
            print_str(benchmark_case->name);
            printf(" mode=hw-in-place run=0x%x\n", run);
            return 1;
        }
    }

    fft_benchmark_summary_t software_summary;
    fft_benchmark_summary_t hardware_out_of_place_summary;
    fft_benchmark_summary_t hardware_in_place_summary;

    summarize_results(software_runs, &software_summary);
    summarize_results(hardware_out_of_place_runs, &hardware_out_of_place_summary);
    summarize_results(hardware_in_place_runs, &hardware_in_place_summary);

    print_str("Case ");
    print_str(benchmark_case->name);
    printf(" (seed=0x%x)\n", benchmark_case->seed);
    print_summary_line("  SW    ", &software_summary);
    print_summary_line("  HW-oop", &hardware_out_of_place_summary);
    print_summary_line("  HW-ip ", &hardware_in_place_summary);
    printf("  Speedup: oop=~0x%xx ip=~0x%xx\n",
           hardware_out_of_place_summary.software_visible_cycles.median
               ? software_summary.software_visible_cycles.median
                     / hardware_out_of_place_summary.software_visible_cycles.median
               : 0u,
           hardware_in_place_summary.software_visible_cycles.median
               ? software_summary.software_visible_cycles.median
                     / hardware_in_place_summary.software_visible_cycles.median
               : 0u);
    print_csv_line(benchmark_case->csv_name, "sw", benchmark_case->seed, &software_summary);
    print_csv_line(benchmark_case->csv_name, "hop", benchmark_case->seed,
                   &hardware_out_of_place_summary);
    print_csv_line(benchmark_case->csv_name, "hip", benchmark_case->seed, &hardware_in_place_summary);

    return 0;
}

int main(void) {
    static const fft_benchmark_case_t benchmark_cases[] = {
        {.name = "impulse", .csv_name = "imp", .seed = 0u, .prepare_input = prepare_impulse_input},
        {.name = "random_seed_13579bdf", .csv_name = "rnd1", .seed = 0x13579BDFu, .prepare_input = prepare_seeded_random_input},
        {.name = "random_seed_2468ace1", .csv_name = "rnd2", .seed = 0x2468ACE1u, .prepare_input = prepare_seeded_random_input},
    };

    uart_init();

    printf("=== FFT Benchmark (N=0x%x, config=0x%x, runs=0x%x, 20 MHz) ===\n", FFT_N, fft_config(), FFT_BENCH_RUNS);

    for (uint32_t index = 0; index < (sizeof(benchmark_cases) / sizeof(benchmark_cases[0])); index++) {
        if (run_benchmark_case(&benchmark_cases[index])) {
            uart_write_flush();
            return 1;
        }
    }

    uart_write_flush();
    return 0;
}
