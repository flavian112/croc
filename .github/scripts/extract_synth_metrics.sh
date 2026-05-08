#!/bin/bash
# Copyright (c) 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# Extract synthesis metrics from Yosys area reports and emit metrics.json.
# Usage: extract_synth_metrics.sh <area_rpt> <out_json>
#   <area_rpt>   path to croc_area.rpt (or croc_idma_area.rpt)
#   <out_json>   path to write the output JSON file

set -euo pipefail

AREA_RPT=${1:-}
OUT_JSON=${2:-}

if [[ -z "$AREA_RPT" || -z "$OUT_JSON" ]]; then
    echo "Usage: $0 <area_rpt> <out_json>" >&2
    exit 1
fi

if [[ ! -f "$AREA_RPT" ]]; then
    echo "Error: report file not found: $AREA_RPT" >&2
    exit 1
fi

# --------------------------------------------------------------------------
# Extract area figures from "Chip area for module" lines.
#
# The report has two kinds of lines:
#   Top-level: Chip area for module '\croc_chip': 921600.000000
#   Submodule: Chip area for module '\bootrom$croc_chip...': 4495.213800
#
# Submodule lines always contain a '$' in the module path; the top-level
# croc_chip line does not. We exploit this to match each entry precisely.
# --------------------------------------------------------------------------

# Total pad ring + soc area: top-level croc_chip (no '$' in the path)
chip_area=$(grep "Chip area for module" "$AREA_RPT" | grep -v '[$]' | grep "croc_chip" | awk '{print $NF}')

# Logic area (no pad cells): croc_soc is the direct child of croc_chip
soc_area=$(grep "Chip area for module" "$AREA_RPT" | grep 'croc_soc[$]croc_chip' | awk '{print $NF}')

# User domain area (contains the FFT accelerator)
user_area=$(grep "Chip area for module" "$AREA_RPT" | grep 'user_domain[$]croc_chip' | awk '{print $NF}')

# Provide null fallback for missing fields
chip_area=${chip_area:-}
soc_area=${soc_area:-}
user_area=${user_area:-}

echo "Synthesis metrics:"
echo "  chip_area_um2   : ${chip_area:-<not found>}"
echo "  soc_area_um2    : ${soc_area:-<not found>}"
echo "  user_domain_um2 : ${user_area:-<not found>}"

# --------------------------------------------------------------------------
# Emit JSON
# --------------------------------------------------------------------------
cat > "$OUT_JSON" <<EOF
{
  "chip_area_um2": ${chip_area:-null},
  "soc_area_um2": ${soc_area:-null},
  "user_domain_um2": ${user_area:-null}
}
EOF

echo "Written: $OUT_JSON"
