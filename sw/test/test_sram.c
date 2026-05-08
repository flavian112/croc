// Copyright (c) 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Authors:
// - Flavian Kaufmann
// - Thanu Kanagalingam

// Test: on-chip SRAM address decoding and basic read/write behavior.
//
// The program itself executes from SRAM and uses SRAM for data and stack, so
// this is intentionally not a destructive full-memory March test. It exercises
// compiler-allocated data, byte enables, the bank boundary, and a large safe
// window in the second bank.

#include <stdint.h>
#include "util.h"

enum {
    SRAM_BASE_ADDR       = 0x10000000u,
    SRAM_BANK_BYTES      = 0x00001000u,
    SRAM_TOTAL_BYTES     = 0x00002000u,
    SRAM_BANK0_LAST_WORD = SRAM_BASE_ADDR + SRAM_BANK_BYTES - 4u,
    SRAM_BANK1_BASE      = SRAM_BASE_ADDR + SRAM_BANK_BYTES,
    SRAM_BANK1_TEST_END  = SRAM_BASE_ADDR + SRAM_TOTAL_BYTES - 0x400u,
};

static volatile uint32_t local_scratch[64];

static uint32_t pattern_for_address(uint32_t address) {
    uint32_t word_index = (address - SRAM_BASE_ADDR) >> 2;
    return 0xA5A50000u ^ (word_index * 0x00010201u);
}

static int test_local_scratch(void) {
    for (uint32_t index = 0; index < 64; index++) {
        local_scratch[index] = 0x13572468u ^ (index * 0x01010101u);
    }

    for (uint32_t index = 0; index < 64; index++) {
        CHECK_ASSERT(10 + index, local_scratch[index] == (0x13572468u ^ (index * 0x01010101u)));
    }

    return 0;
}

static int test_byte_enables(void) {
    volatile uint32_t *word = (volatile uint32_t *)SRAM_BANK1_BASE;
    volatile uint8_t *byte  = (volatile uint8_t *)SRAM_BANK1_BASE;

    *word                   = 0x11223344u;
    CHECK_ASSERT(100, *word == 0x11223344u);

    byte[0] = 0xAAu;
    CHECK_ASSERT(101, *word == 0x112233AAu);

    byte[1] = 0xBBu;
    CHECK_ASSERT(102, *word == 0x1122BBAAu);

    byte[2] = 0xCCu;
    CHECK_ASSERT(103, *word == 0x11CCBBAAu);

    byte[3] = 0xDDu;
    CHECK_ASSERT(104, *word == 0xDDCCBBAAu);

    return 0;
}

static int test_bank_boundary(void) {
    volatile uint32_t *bank0_last  = (volatile uint32_t *)SRAM_BANK0_LAST_WORD;
    volatile uint32_t *bank1_first = (volatile uint32_t *)SRAM_BANK1_BASE;

    *bank0_last                    = 0x0BADB000u;
    *bank1_first                   = 0x0BADB001u;

    CHECK_ASSERT(200, *bank0_last == 0x0BADB000u);
    CHECK_ASSERT(201, *bank1_first == 0x0BADB001u);

    *bank0_last = 0x55AA00FFu;
    CHECK_ASSERT(202, *bank0_last == 0x55AA00FFu);
    CHECK_ASSERT(203, *bank1_first == 0x0BADB001u);

    return 0;
}

static int test_upper_bank_sweep(void) {
    for (uint32_t address = SRAM_BANK1_BASE; address < SRAM_BANK1_TEST_END; address += 4u) {
        *(volatile uint32_t *)address = pattern_for_address(address);
    }

    for (uint32_t address = SRAM_BANK1_BASE; address < SRAM_BANK1_TEST_END; address += 4u) {
        CHECK_ASSERT(300, *(volatile uint32_t *)address == pattern_for_address(address));
    }

    for (uint32_t address = SRAM_BANK1_BASE; address < SRAM_BANK1_TEST_END; address += 4u) {
        *(volatile uint32_t *)address = ~pattern_for_address(address);
    }

    for (uint32_t address = SRAM_BANK1_BASE; address < SRAM_BANK1_TEST_END; address += 4u) {
        CHECK_ASSERT(301, *(volatile uint32_t *)address == ~pattern_for_address(address));
    }

    return 0;
}

int main(void) {
    CHECK_CALL(test_local_scratch());
    CHECK_CALL(test_byte_enables());
    CHECK_CALL(test_bank_boundary());
    CHECK_CALL(test_upper_bank_sweep());

    return 0;
}
