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
    echo "Usage: $0 <variant-name> [verilator-flags] [riscv-ccflags]" >&2
    exit 1
fi

cd "$CROC_ROOT"

echo "============================================="
echo "FFT variant: $VARIANT_NAME"
echo "============================================="
echo "VERILATOR_FLAGS: ${VERILATOR_VARIANT_FLAGS:-<default>}"
echo "RISCV_EXTRA_CCFLAGS: ${RISCV_VARIANT_FLAGS:-<none>}"

make clean-sw clean-sim

make_args=(test-fft)
if [[ -n "$VERILATOR_VARIANT_FLAGS" ]]; then
    make_args+=("VERILATOR_FLAGS=$VERILATOR_VARIANT_FLAGS")
fi
if [[ -n "$RISCV_VARIANT_FLAGS" ]]; then
    make_args+=("RISCV_EXTRA_CCFLAGS=$RISCV_VARIANT_FLAGS")
fi

sim_start=$(date +%s)
make "${make_args[@]}"
sim_end=$(date +%s)
sim_runtime=$(( sim_end - sim_start ))

cd verilator
cp -f croc.log "fft-${VARIANT_NAME}.log"
if [[ -f croc.fst ]]; then
    cp -f croc.fst "fft-${VARIANT_NAME}.fst"
fi

cat > "fft-${VARIANT_NAME}-metrics.json" <<METRICSEOF
{
  "variant": "${VARIANT_NAME}",
  "sim_runtime_seconds": ${sim_runtime}
}
METRICSEOF
echo "Variant metrics written to verilator/fft-${VARIANT_NAME}-metrics.json"

echo ""
echo "============================================="
echo "FFT variant ${VARIANT_NAME} completed"
echo "============================================="