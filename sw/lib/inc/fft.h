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

/**
 * @file fft.h
 * @brief Software interface for the memory-mapped FFT accelerator.
 *
 * The accelerator computes one fixed-size complex FFT over a buffer in memory.
 * Input and output samples use the same packed 32-bit representation:
 *
 *   sample[31:16] = signed 16-bit real component
 *   sample[15:0]  = signed 16-bit imaginary component
 *
 * Hardware implements a synthesized radix-2 FFT length selected at build time.
 * Software assumes FFT_SYNTH_LENGTH from config.h and validates at runtime
 * against the CONFIG register.
 *
 * The CONFIG register exposes the synthesized FFT length, data width, and
 * enabled build options. The CYCLES register latches the number of accelerator
 * clock cycles used by the previous DMA plus compute transaction.
 *
 * STATUS.DONE is sticky. Software clears it by writing a one to the DONE bit.
 * Starting a new transfer also clears the previous DONE indication.
 *
 * A blocking transfer is normally issued with fft_run(). Lower-level helpers
 * are provided for tests, benchmarks, and code that wants to poll or use the
 * interrupt-enable register directly.
 */

/**
 * @brief Number of complex samples consumed and produced by one accelerator run.
 */
enum {
    FFT_N = FFT_SYNTH_LENGTH,
};

/**
 * @brief Compile-time FFT scaling modes reported by the CONFIG register.
 */
enum {
    FFT_SCALE_NONE       = 0,
    FFT_SCALE_EACH_STAGE = 1,
};

/**
 * @brief Packed complex FFT sample, formatted as {real[15:0], imag[15:0]}.
 */
typedef uint32_t fft_sample_t;

/**
 * @brief Pack signed real and imaginary components into one accelerator sample.
 *
 * Arguments are narrowed to int16_t before packing. This is intentional and
 * matches the hardware register/memory format.
 */
#define FFT_SAMPLE(real, imag)      ((((uint32_t)(uint16_t)(int16_t)(real)) << 16) | ((uint16_t)(int16_t)(imag)))

/**
 * @name Register offsets
 *
 * Offsets are relative to FFT_BASE_ADDR.
 */
/** @{ */
#define FFT_CTRL_OFFSET             0x00
#define FFT_STATUS_OFFSET           0x04
#define FFT_SRC_ADDR_OFFSET         0x08
#define FFT_DST_ADDR_OFFSET         0x0C
#define FFT_IRQ_CTRL_OFFSET         0x10
#define FFT_CONFIG_OFFSET           0x14
#define FFT_CYCLES_OFFSET           0x18
/** @} */

/**
 * @name CTRL register bits
 */
/** @{ */
#define FFT_CTRL_START_BIT          0
/** @} */

/**
 * @name STATUS register bits
 */
/** @{ */
#define FFT_STATUS_BUSY_BIT         0
#define FFT_STATUS_DONE_BIT         1
/** @} */

/**
 * @name CONFIG register fields
 */
/** @{ */
#define FFT_CONFIG_LENGTH_MASK      0x000000FFu
#define FFT_CONFIG_LOG2_SHIFT       8
#define FFT_CONFIG_LOG2_MASK        0x00000F00u
#define FFT_CONFIG_DATA_WIDTH_SHIFT 16
#define FFT_CONFIG_DATA_WIDTH_MASK  0x00FF0000u
#define FFT_CONFIG_INVERSE_BIT      24
#define FFT_CONFIG_SCALE_MODE_SHIFT 25
#define FFT_CONFIG_SCALE_MODE_MASK  0x06000000u
#define FFT_CONFIG_BIT_REVERSE_BIT  27
/** @} */

/**
 * @brief Pack signed real and imaginary components into one accelerator sample.
 */
static inline fft_sample_t fft_pack(int16_t real, int16_t imag) {
    return FFT_SAMPLE(real, imag);
}

/**
 * @brief Extract the signed real component from a packed accelerator sample.
 */
static inline int16_t fft_real(fft_sample_t sample) {
    return (int16_t)(sample >> 16);
}

/**
 * @brief Extract the signed imaginary component from a packed accelerator sample.
 */
static inline int16_t fft_imag(fft_sample_t sample) {
    return (int16_t)sample;
}

/**
 * @brief Write one FFT accelerator register.
 *
 * @param offset Register offset relative to FFT_BASE_ADDR.
 * @param value  Value to write.
 */
static inline void fft_write_reg(uint32_t offset, uint32_t value) {
    *reg32(FFT_BASE_ADDR, offset) = value;
}

/**
 * @brief Read one FFT accelerator register.
 *
 * @param offset Register offset relative to FFT_BASE_ADDR.
 * @return Current register value.
 */
static inline uint32_t fft_read_reg(uint32_t offset) {
    return *reg32(FFT_BASE_ADDR, offset);
}

/**
 * @brief Read the accelerator STATUS register.
 *
 * Bit FFT_STATUS_BUSY_BIT is set while a run is active. Bit
 * FFT_STATUS_DONE_BIT is set when a run has completed and remains set until
 * cleared with fft_clear_done() or by starting another run.
 */
static inline uint32_t fft_status(void) {
    return fft_read_reg(FFT_STATUS_OFFSET);
}

/**
 * @brief Return non-zero while the accelerator is processing a run.
 */
static inline int fft_busy(void) {
    return (fft_status() >> FFT_STATUS_BUSY_BIT) & 1u;
}

/**
 * @brief Return non-zero once the accelerator has completed the current run.
 */
static inline int fft_done(void) {
    return (fft_status() >> FFT_STATUS_DONE_BIT) & 1u;
}

/**
 * @brief Clear the sticky DONE status bit.
 *
 * The STATUS register uses write-one-to-clear semantics for DONE. Other bits
 * ignore writes.
 */
static inline void fft_clear_done(void) {
    fft_write_reg(FFT_STATUS_OFFSET, 1u << FFT_STATUS_DONE_BIT);
}

/**
 * @brief Read the accelerator CONFIG register.
 */
static inline uint32_t fft_config(void) {
    return fft_read_reg(FFT_CONFIG_OFFSET);
}

/**
 * @brief Return the synthesized FFT length reported by hardware.
 */
static inline uint32_t fft_config_length(void) {
    return fft_config() & FFT_CONFIG_LENGTH_MASK;
}

/**
 * @brief Return log2 of the synthesized FFT length.
 */
static inline uint32_t fft_config_log2_length(void) {
    return (fft_config() & FFT_CONFIG_LOG2_MASK) >> FFT_CONFIG_LOG2_SHIFT;
}

/**
 * @brief Return the synthesized signed component width in bits.
 */
static inline uint32_t fft_config_data_width(void) {
    return (fft_config() & FFT_CONFIG_DATA_WIDTH_MASK) >> FFT_CONFIG_DATA_WIDTH_SHIFT;
}

/**
 * @brief Return non-zero when hardware is built as an inverse FFT.
 */
static inline int fft_config_inverse(void) {
    return (fft_config() >> FFT_CONFIG_INVERSE_BIT) & 1u;
}

/**
 * @brief Return the synthesized fixed-point scaling mode.
 */
static inline uint32_t fft_config_scale_mode(void) {
    return (fft_config() & FFT_CONFIG_SCALE_MODE_MASK) >> FFT_CONFIG_SCALE_MODE_SHIFT;
}

/**
 * @brief Return non-zero when each butterfly stage scales by one bit.
 */
static inline int fft_config_scale_stages(void) {
    return fft_config_scale_mode() == FFT_SCALE_EACH_STAGE;
}

/**
 * @brief Return non-zero when input samples are loaded in bit-reversed order.
 */
static inline int fft_config_bit_reverse(void) {
    return (fft_config() >> FFT_CONFIG_BIT_REVERSE_BIT) & 1u;
}

/**
 * @brief Read the accelerator cycle count from the previous completed run.
 */
static inline uint32_t fft_cycles(void) {
    return fft_read_reg(FFT_CYCLES_OFFSET);
}

/**
 * @brief Set the source buffer address.
 *
 * The buffer must contain at least FFT_N packed samples and must remain valid
 * until the accelerator has finished.
 */
static inline void fft_set_src(const fft_sample_t *src) {
    fft_write_reg(FFT_SRC_ADDR_OFFSET, (uint32_t)src);
}

/**
 * @brief Set the destination buffer address.
 *
 * The buffer must provide space for at least FFT_N packed samples and must
 * remain valid until the accelerator has finished.
 */
static inline void fft_set_dst(fft_sample_t *dst) {
    fft_write_reg(FFT_DST_ADDR_OFFSET, (uint32_t)dst);
}

/**
 * @brief Enable or disable the accelerator completion interrupt.
 *
 * The interrupt output remains asserted while both IRQ enable and sticky DONE
 * are set. Clear DONE in the interrupt handler to deassert it.
 */
static inline void fft_irq_enable(int enable) {
    fft_write_reg(FFT_IRQ_CTRL_OFFSET, enable ? 1u : 0u);
}

/**
 * @brief Start one FFT run.
 *
 * Source and destination addresses must be programmed before calling this
 * function. The START bit self-clears in hardware.
 */
static inline void fft_start(void) {
    fft_write_reg(FFT_CTRL_OFFSET, 1u << FFT_CTRL_START_BIT);
}

/**
 * @brief Busy-wait until the accelerator reports completion.
 */
static inline void fft_wait_done(void) {
    while (!fft_done())
        ;
}

/**
 * @brief Run one blocking FFT transfer.
 *
 * This convenience helper programs the source and destination pointers, starts
 * the accelerator, and waits for completion.
 */
static inline void fft_run(const fft_sample_t *src, fft_sample_t *dst) {
    fft_set_src(src);
    fft_set_dst(dst);
    fft_start();
    fft_wait_done();
}
