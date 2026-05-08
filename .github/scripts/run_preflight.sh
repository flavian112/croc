#!/bin/bash
# Copyright (c) 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# Preflight smoke simulation: lint + format + config sanity + helloworld smoke test

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CROC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cleanup() {
  "$SCRIPT_DIR/set_croc_config.sh"
}

trap cleanup EXIT

cd "$CROC_ROOT"

echo "============================================="
echo "Preflight: default config smoke simulation"
echo "============================================="

"$SCRIPT_DIR/set_croc_config.sh"

make -C sw

cd verilator
./run_verilator.sh --build
./run_verilator.sh --run ../sw/bin/helloworld.hex
grep -q "\[UART\] Hello World from Croc!" croc.log

./run_verilator.sh --run ../sw/bin/test/print_config.hex
"$SCRIPT_DIR/check_sim.sh" croc.log

cd "$CROC_ROOT"
git diff --exit-code -- rtl/croc_pkg.sv

echo ""
echo "============================================="
echo " Preflight completed"
echo "============================================="
