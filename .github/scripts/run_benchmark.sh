#!/bin/bash
# Copyright (c) 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CROC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cleanup() {
    "$SCRIPT_DIR/set_croc_config.sh"
}

trap cleanup EXIT

cd "$CROC_ROOT"

echo "============================================="
echo "FFT benchmark"
echo "============================================="

"$SCRIPT_DIR/set_croc_config.sh"

make clean-sw clean-sim
make bench-fft

if ! grep -q '\[UART\] BENCH_CSV,' verilator/croc.log; then
    echo "Error: benchmark log does not contain BENCH_CSV output" >&2
    exit 1
fi

printf '%s\n' 'case,mode,runs,seed,visible_min,visible_median,visible_max,accelerator_min,accelerator_median,accelerator_max,overhead_min,overhead_median,overhead_max,bin0,bin_mid' > verilator/fft_benchmark.csv
awk '/\[UART\] BENCH_CSV,/ { sub(/^.*\[UART\] BENCH_CSV,/, ""); print }' verilator/croc.log >> verilator/fft_benchmark.csv
cp -f verilator/croc.log verilator/fft_benchmark.log

echo "Benchmark CSV extracted to verilator/fft_benchmark.csv"