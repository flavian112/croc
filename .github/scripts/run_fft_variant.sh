#!/bin/bash
# Copyright (c) 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CROC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

VARIANT_NAME=${1:-}
VERILATOR_VARIANT_FLAGS=${2:-}
RISCV_VARIANT_FLAGS=${3:-}

if [[ -z "$VARIANT_NAME" ]]; then
    echo "Usage: $0 <variant-name> [verilator-flags] [riscv-extra-ccflags]" >&2
    exit 1
fi

cd "$CROC_ROOT"

echo "============================================="
echo "FFT variant: $VARIANT_NAME"
echo "============================================="
echo "VERILATOR_FLAGS: ${VERILATOR_VARIANT_FLAGS:-<default>}"
echo "RISCV_EXTRA_CCFLAGS: ${RISCV_VARIANT_FLAGS:-<none>}"

make clean-sw clean-sim

make_args_common=()
if [[ -n "$VERILATOR_VARIANT_FLAGS" ]]; then
    make_args_common+=("VERILATOR_FLAGS=$VERILATOR_VARIANT_FLAGS")
fi
if [[ -n "$RISCV_VARIANT_FLAGS" ]]; then
    make_args_common+=("RISCV_EXTRA_CCFLAGS=$RISCV_VARIANT_FLAGS")
fi

test_start=$(date +%s)
make test-fft "${make_args_common[@]}"
test_end=$(date +%s)
test_runtime=$(( test_end - test_start ))

cd verilator
cp -f croc.log "fft-${VARIANT_NAME}.log"
if [[ -f croc.fst ]]; then
    cp -f croc.fst "fft-${VARIANT_NAME}.fst"
fi

cd "$CROC_ROOT"
# Rebuild the simulator for the benchmark while preserving the copied
# correctness artifacts above for CI upload.
rm -rf verilator/obj_dir verilator/croc.log verilator/croc.fst verilator/croc_build.log

bench_start=$(date +%s)
make bench-fft "${make_args_common[@]}"
bench_end=$(date +%s)
bench_runtime=$(( bench_end - bench_start ))

cd verilator
cp -f croc.log "fft-${VARIANT_NAME}-bench.log"

if ! grep -q '\[UART\] BENCH_CSV,' croc.log; then
    echo "Error: benchmark log does not contain BENCH_CSV output for variant ${VARIANT_NAME}" >&2
    exit 1
fi

printf '%s\n' 'case,mode,runs,seed,visible_min,visible_median,visible_max,accelerator_min,accelerator_median,accelerator_max,overhead_min,overhead_median,overhead_max,bin0,bin_mid' > "fft-${VARIANT_NAME}-benchmark.csv"
awk '/\[UART\] BENCH_CSV,/ { sub(/^.*\[UART\] BENCH_CSV,/, ""); print }' croc.log >> "fft-${VARIANT_NAME}-benchmark.csv"

rnd1_sw_visible_median=$(awk -F',' '$1=="rnd1" && $2=="sw" {print $6; exit}' "fft-${VARIANT_NAME}-benchmark.csv")
rnd1_hop_visible_median=$(awk -F',' '$1=="rnd1" && $2=="hop" {print $6; exit}' "fft-${VARIANT_NAME}-benchmark.csv")
rnd1_hip_visible_median=$(awk -F',' '$1=="rnd1" && $2=="hip" {print $6; exit}' "fft-${VARIANT_NAME}-benchmark.csv")

total_runtime=$(( test_runtime + bench_runtime ))

cat > "fft-${VARIANT_NAME}-metrics.json" <<METRICSEOF
{
  "variant": "${VARIANT_NAME}",
  "test_runtime_seconds": ${test_runtime},
  "bench_runtime_seconds": ${bench_runtime},
  "sim_runtime_seconds": ${total_runtime},
  "rnd1_sw_visible_median_hex": "${rnd1_sw_visible_median:-}",
  "rnd1_hop_visible_median_hex": "${rnd1_hop_visible_median:-}",
  "rnd1_hip_visible_median_hex": "${rnd1_hip_visible_median:-}"
}
METRICSEOF
echo "Variant metrics written to verilator/fft-${VARIANT_NAME}-metrics.json"

echo ""
echo "============================================="
echo "FFT variant ${VARIANT_NAME} completed"
echo "============================================="
