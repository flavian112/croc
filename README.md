# FFTodile

FFTodile is a small FFT accelerator chip project built on top of the Croc
educational SoC. It combines a CVE2 RISC-V core, SRAM, OBI interconnect,
standard peripherals, and a custom user-domain FFT accelerator. The physical
implementation targets the open-source IHP SG13G2 130 nm PDK.

The repository contains RTL, bare-metal software, Verilator simulation, Yosys
synthesis, OpenROAD backend scripts, KLayout finishing, CI automation, and the
ArtistIC rendering flow used for mask-art and GitHub Pages previews.

## Contents

- [Project Overview](#project-overview)
- [Quick Start](#quick-start)
- [Repository Layout](#repository-layout)
- [Architecture](#architecture)
- [FFT Accelerator](#fft-accelerator)
- [Software Interface](#software-interface)
- [Build and Verification](#build-and-verification)
- [ASIC Flow](#asic-flow)
- [ArtistIC Flow](#artistic-flow)
- [Configuration](#configuration)
- [GitHub Actions](#github-actions)
- [Development Guidelines](#development-guidelines)
- [Upstream and License](#upstream-and-license)

## Project Overview

Current user-domain contents:

| Path | Purpose |
| --- | --- |
| `rtl/user_domain/fft/fft_obi.sv` | Memory-mapped OBI wrapper, register bank, memory transfers, interrupt, and cycle counter |
| `rtl/user_domain/fft/fft_core.sv` | Compact iterative fixed-point radix-2 FFT datapath |
| `rtl/user_domain/user_rom.sv` | Read-only chip identification string |
| `sw/lib/inc/fft.h` | Bare-metal FFT accelerator API |
| `sw/lib/inc/fft_ref.h` | Fixed-point software reference model for tests and benchmarks |
| `sw/test/test_fft.c` | Deterministic FFT correctness test |
| `sw/test/test_sram.c` | SRAM address/data test |
| `sw/benchmark_fft.c` | Software-vs-hardware FFT benchmark |

The default build is a 16-point, forward, Q1.15-style fixed-point FFT with one
arithmetic right shift per butterfly stage. Other supported compile-time
variants are exercised in CI.

## Quick Start

Initialize submodules once:

```sh
make init
```

Start the intended tool environment:

```sh
scripts/start_linux.sh
```

Inside the container shell, run the local preflight before pushing changes:

```sh
make preflight
```

Useful day-to-day commands:

```sh
make help
make sw
make test-fft
make bench-fft
make test-sram
make sim BIN=sw/bin/test/print_config.hex
make synth
make flow
```

`make preflight` is the closest local equivalent to the GitHub preflight smoke
job. It runs script syntax checks, restores the default configuration, runs
helloworld and print-config simulation, validates SoC introspection output, and
checks the default FFT correctness/benchmark metrics.

## Repository Layout

```text
rtl/                  SystemVerilog SoC and user-domain RTL
rtl/user_domain/      FFTodile user-domain RTL
sw/                   Bare-metal software, tests, benchmark, and headers
verilator/            Verilator simulation flow
yosys/                Yosys synthesis flow
openroad/             Floorplan, placement, CTS, routing, and finishing flow
klayout/              DEF-to-GDS, seal ring, and fill flow
artistic/             ArtistIC logo/render/map flow
ihp13/                IHP SG13G2 technology integration and PDK submodule
scripts/              Developer helper scripts and formatting tools
.github/              CI workflows, composite actions, and CI helper scripts
doc/                  Documentation images
```

## Architecture

FFTodile keeps the original Croc split between the main SoC and the user domain.

![Croc block diagram](doc/croc_arch.svg)

Main blocks:

- `croc_domain`: CVE2 core, SRAM banks, debug module, main OBI interconnect,
  SoC control, CLINT, UART, GPIO, timer, and optional iDMA.
- `user_domain`: user ROM, FFT accelerator, and an error subordinate for
  unmapped user-domain accesses.
- `fft_obi`: software-visible FFT register interface, source/destination memory
  transfers, status, interrupt enable, and cycle accounting.
- `fft_core`: iterative radix-2 FFT engine with local storage and a reused
  butterfly datapath.

The main interconnect protocol is OBI. Most generated physical outputs are
ignored by git and should be treated as build artifacts.

Current layout snapshots:

| Module Placement | Routed Design |
| :---: | :---: |
| <img src="doc/fftodile_modules.jpg" alt="FFTodile module placement" width="420"> | <img src="doc/fftodile_routed.jpg" alt="FFTodile routed design" width="420"> |

## Memory Map

Default platform address ranges:

| Start | End | Region |
| --- | --- | --- |
| `0x0000_0000` | `0x0004_0000` | Debug module |
| `0x0200_0000` | `0x0200_4000` | Boot ROM |
| `0x0204_0000` | `0x0208_0000` | CLINT |
| `0x0300_0000` | `0x0300_1000` | SoC control/info registers |
| `0x0300_2000` | `0x0300_3000` | UART |
| `0x0300_5000` | `0x0300_6000` | GPIO |
| `0x0300_A000` | `0x0300_B000` | OBI timer |
| `0x0300_B000` | `0x0300_C000` | Optional iDMA registers |
| `0x1000_0000` | `+SRAM_SIZE` | SRAM banks |
| `0x2000_0000` | `0x2000_1000` | User ROM |
| `0x2000_1000` | `...` | FFT accelerator |

The user ROM returns:

```text
FFTodile REV 1.0 - Flavian Kaufmann, Thanu Kanagalingam
```

## FFT Accelerator

Samples are packed into one 32-bit word:

```text
sample[31:16] = signed 16-bit real component
sample[15:0]  = signed 16-bit imaginary component
```

Top-level compile-time parameters:

| Parameter | Default | Description |
| --- | --- | --- |
| `FftLength` | `16` | Number of complex samples per run |
| `FftDataWidth` | `16` | Signed bits per real/imaginary component |
| `FftScalingMode` | `1` | `0`: no butterfly scaling, `1`: scale each stage |
| `FftInverse` | `0` | `0`: forward FFT, `1`: inverse FFT |
| `FftUseRounding` | `0` | `0`: truncate scaled results, `1`: round-half-up before shift |
| `FftUseSaturation` | `0` | `0`: wrap on overflow, `1`: saturate to signed min/max |

Supported RTL lengths are 2, 4, 8, and 16 points. The default 16-point build and
a representative 8-point build are covered by simulation. The software
reference model currently supports the verified 8-point and 16-point cases.

Register map relative to `FFT_BASE_ADDR = 0x2000_1000`:

| Offset | Register | Description |
| --- | --- | --- |
| `0x00` | `CTRL` | Bit 0 starts one run |
| `0x04` | `STATUS` | Bit 0 busy, bit 1 sticky done; write 1 to bit 1 to clear |
| `0x08` | `SRC_ADDR` | Source buffer address |
| `0x0C` | `DST_ADDR` | Destination buffer address |
| `0x10` | `IRQ_CTRL` | Bit 0 enables completion interrupt while done is set |
| `0x14` | `CONFIG` | Synthesized FFT length, width, scaling mode, and build flags |
| `0x18` | `CYCLES` | Accelerator cycle count for the previous run |

`CONFIG` fields:

| Bits | Field | Description |
| --- | --- | --- |
| `[7:0]` | `LENGTH` | Synthesized FFT length |
| `[11:8]` | `LOG2_LENGTH` | `log2(LENGTH)` |
| `[23:16]` | `DATA_WIDTH` | Signed component width |
| `[24]` | `INVERSE` | Inverse FFT build flag |
| `[26:25]` | `SCALE_MODE` | `0`: no scaling, `1`: scale each stage |
| `[27]` | `BIT_REVERSE` | Input is loaded in bit-reversed order |

## Software Interface

The public bare-metal API lives in `sw/lib/inc/fft.h`.

Minimal usage:

```c
#include "fft.h"

static fft_sample_t input[FFT_N];
static fft_sample_t output[FFT_N];

input[0] = fft_pack(0x1000, 0);
for (int i = 1; i < FFT_N; i++) {
    input[i] = 0;
}

fft_run(input, output);
```

The API exposes register access helpers, configuration decoding, busy/done
status, optional interrupt enable, cycle count reads, and blocking
out-of-place/in-place runs. Tests and benchmarks use `sw/lib/inc/fft_ref.h` as
the fixed-point reference model.

For non-default FFT simulations, keep hardware and software compile-time flags
aligned. Examples:

```sh
# Disable per-stage scaling.
make clean-sim
make test-fft VERILATOR_FLAGS=-GFftScalingMode=0

# Inverse FFT with rounding and saturation.
make clean-sim
make test-fft \
  VERILATOR_FLAGS='-GFftInverse=1 -GFftUseRounding=1 -GFftUseSaturation=1' \
  RISCV_EXTRA_CCFLAGS='-DFFT_REF_USE_INVERSE=1 -DFFT_REF_USE_ROUNDING=1 -DFFT_REF_USE_SATURATION=1'

# 8-point FFT build.
make clean-sim
make test-fft \
  VERILATOR_FLAGS='-GFftLength=8' \
  RISCV_EXTRA_CCFLAGS='-DFFT_SYNTH_LENGTH=8 -DFFT_SYNTH_LOG2_LENGTH=3'
```

## Build and Verification

Top-level Makefile variables:

| Variable | Default | Use |
| --- | --- | --- |
| `PROJ_NAME` | `croc` | Backend/finishing project name |
| `TOP_DESIGN` | `croc_chip` | Physical-flow top design |
| `BIN` | `sw/bin/helloworld.hex` | Hex image used by `make sim` |
| `VERILATOR_FLAGS` | empty | Extra Verilator/top-parameter flags |

Main targets:

| Target | Purpose |
| --- | --- |
| `make init` | Initialize submodules |
| `make sw` | Build all software images |
| `make lint` | Check Python and C/C++ formatting |
| `make lint-fix` | Apply formatting fixes |
| `make preflight` | Run local CI-like smoke/regression checks |
| `make sim BIN=...` | Build software, build Verilator, and run one hex image |
| `make test-fft` | Run FFT correctness simulation |
| `make bench-fft` | Run FFT benchmark simulation |
| `make test-sram` | Run SRAM address/data simulation |
| `make flist` | Regenerate generated file lists |
| `make clean` | Remove generated software, simulation, and flow outputs |

The benchmark reports:

- software-visible cycle count for software FFT
- software-visible cycle count for hardware FFT
- accelerator-reported cycle count from `CYCLES`
- estimated host/transfer overhead
- out-of-place and in-place hardware runs
- `BENCH_CSV,...` lines consumed by CI

Print-config introspection is validated by `.github/scripts/check_print_config.py`.
It checks the SoC info word, SRAM sizing, generated peripheral base addresses,
optional iDMA presence, user ROM contents, and basic JTAG/core execution
sequence.

## ASIC Flow

The ASIC flow is wrapped by the top-level Makefile:

```text
Bender/file lists -> Yosys -> OpenROAD -> KLayout
```

Stage targets:

| Target | Stage |
| --- | --- |
| `make synth` | Yosys synthesis |
| `make floorplan` | OpenROAD floorplan |
| `make placement` | OpenROAD placement |
| `make cts` | OpenROAD clock-tree synthesis |
| `make routing` | OpenROAD routing |
| `make finishing` | OpenROAD finishing |
| `make backend` | All OpenROAD stages |
| `make gds` | KLayout DEF-to-GDS |
| `make seal` | Merge seal ring |
| `make fill` | Add fill |
| `make flow` | `synth backend gds seal` |

Clean targets:

| Target | Removed outputs |
| --- | --- |
| `make clean-sw` | `sw/bin`, `sw/build` |
| `make clean-sim` | Verilator build/log/waveform outputs |
| `make clean-flow` | Yosys, OpenROAD, and KLayout outputs |
| `make clean` | All of the above |

Generated logs, reports, waveforms, OpenROAD outputs, and GDS outputs are not
intended to be committed.

## ArtistIC Flow

The `artistic/` directory contains the rendering flow for GitHub Pages and
top-metal artwork previews. This flow is separate from functional RTL
verification.

Typical local sequence:

On the host, with Inkscape and ImageMagick available:

```sh
cd artistic
./run_artistic.sh --prepare-logo
```

Inside the OSEDA container:

```sh
cd /fosic/designs/croc/artistic
./run_artistic.sh --create-logo croc.sealed.gds.gz
./run_artistic.sh --render-raw
./run_artistic.sh --render-map-raw
```

Back on the host:

```sh
cd artistic
./run_artistic.sh --render-pdf
./run_artistic.sh --outline
./run_artistic.sh --render-map-db
cd mapify
python3 -m http.server 8000
```

Open `http://localhost:8000` to inspect the generated map viewer.

## Configuration

Main configuration sources:

| Source | Owns |
| --- | --- |
| `rtl/croc_pkg.sv` | SoC configuration, core selection, SRAM sizing, main address map |
| `rtl/user_pkg.sv` | User-domain address map |
| `rtl/test/tb_croc_pkg.sv` | Verilator testbench clock/UART defaults |
| `rtl/croc_chip.sv` | Default FFT top-level parameters exposed to software |
| `scripts/generate_sw_config.py` | Generation of `sw/config.h` from RTL sources |

`sw/config.h` is generated. Do not edit it by hand. It is refreshed by normal
software builds such as `make sw`, `make test-fft`, and `make preflight`.

Current default SRAM configuration:

- `NumSramBanks = 2`
- `SramBankNumWords = 1024`

The technology-specific SRAM mapping is implemented through
`ihp13/tc_sram_impl.sv`.

The PDK is a git submodule under `ihp13/pdk` and is patched by `env.sh` during
tool setup. If git reports that submodule as dirty after the patch is applied,
use:

```sh
git config submodule.ihp13/pdk.ignore dirty
```

## GitHub Actions

All GitHub-owned JavaScript actions are pinned to Node 24-capable major
versions.

| Workflow | Triggers | Purpose |
| --- | --- | --- |
| `Preflight` | PRs, pushes to any branch, manual | Static checks first, then local preflight smoke simulation |
| `Short Flow` | PRs, pushes to `main`, manual | Simulation regression, FFT variant matrix with benchmark metrics, and synthesis metrics |
| `Full Flow` | Successful `Short Flow` on `main`, releases, manual | Yosys/OpenROAD/KLayout full backend flow through sealed GDS |
| `ArtistIC Render` | Successful Full Flow on `main`, pushes to `artistic/**`, manual | Logo/artistic rendering, map generation, GitHub Pages deployment |

The intended pipeline order is:

```text
Preflight -> Short Flow -> Full Flow -> ArtistIC Render
```

Preflight and Short Flow both run on pull requests. Full Flow is intentionally
kept out of the normal PR path because it is much heavier; it runs automatically
after Short Flow succeeds on `main`, or when triggered manually/release-driven.

Important CI scripts:

| Script | Purpose |
| --- | --- |
| `.github/scripts/run_preflight.sh` | Local/CI preflight smoke and default FFT regression |
| `.github/scripts/run_sim_flow.sh` | Default smoke simulation plus iDMA-enabled unit tests |
| `.github/scripts/run_fft_variant.sh` | One FFT build variant test+benchmark+metrics run |
| `.github/scripts/run_benchmark.sh` | Standalone FFT benchmark artifact generation |
| `.github/scripts/run_synth_flow.sh` | Synthesis run and metrics extraction |
| `.github/scripts/run_full_flow.sh` | Full physical flow |
| `.github/scripts/check_print_config.py` | Print-config log validator |
| `.github/scripts/check_metrics.py` | Variant and synthesis metric threshold checks |

CI regression thresholds live in `.github/metrics/baseline.json`. Update them
deliberately when a measured regression or improvement is expected. Generated
per-run metrics should remain CI artifacts, not committed files.

## Development Guidelines

For RTL source membership changes:

1. Update `Bender.yml`.
2. Run `make flist`.
3. Run at least `make test-fft`.
4. For synthesis-impacting changes, run `make synth`.

For SoC or address-map changes:

1. Edit the canonical RTL source.
2. Refresh generated software constants with `make sw`.
3. Run `make sim BIN=sw/bin/test/print_config.hex`.
4. Run `.github/scripts/check_sim.sh verilator/croc.log` if you did not run a
   wrapper flow that already calls it.
5. Update documentation if the change is user-visible.

For FFT operating-mode changes:

1. Keep Verilator top-parameter overrides and software reference-model macros
   aligned.
2. If a default FFT parameter changes, update the default in `rtl/croc_chip.sv`
   so generated software constants remain correct.
3. Add or update a representative entry in the `Short Flow` FFT variant matrix.
4. Run the default test plus the affected variant locally.

Recommended validation:

| Change type | Minimum local check |
| --- | --- |
| Formatting only | `make lint` |
| FFT datapath or software model | `make test-fft` |
| SoC/config/introspection | `make sim BIN=sw/bin/test/print_config.hex` |
| Synthesis-impacting RTL | `make synth` |
| PR-ready branch | `make preflight` |

## Upstream and License

This repository is based on Croc, an educational SoC developed as part of the
PULP project by ETH Zurich and the University of Bologna. FFTodile keeps that
infrastructure and replaces the generic user-design area with the FFT
accelerator project.

Unless specified otherwise in individual file headers, hardware sources and tool
scripts are licensed under the Solderpad Hardware License 0.51. Software sources
are licensed under Apache 2.0. See `LICENSE.md` and file headers for details.
