# FFTodile

FFTodile is a small FFT accelerator chip project built on top of the Croc
educational SoC. The design uses a CVE2 RISC-V core, SRAM, a simple OBI
interconnect, common SoC peripherals, and a custom user-domain FFT accelerator.

The physical implementation targets the open-source IHP SG13G2 130 nm PDK. The
repository contains the RTL, bare-metal software, simulation setup, synthesis,
place-and-route, KLayout finishing scripts, and artistic mask-generation support
used for the project.

## Project Status

Current user-domain contents:

- `rtl/user_domain/fft/fft_obi.sv`: memory-mapped OBI register/DMA wrapper for the FFT accelerator
- `rtl/user_domain/fft/fft_core.sv`: compact iterative fixed-point FFT core
- `rtl/user_domain/user_rom.sv`: user ROM containing the chip ID string
- `sw/lib/inc/fft.h`: bare-metal software API for the FFT accelerator
- `sw/test/test_fft.c`: deterministic correctness tests
- `sw/benchmark_fft.c`: software-vs-hardware benchmark

The FFT accelerator is a compile-time configured fixed-point radix-2 engine.
Supported RTL lengths are 2/4/8/16 points, with 8-point and 16-point builds
currently verified in simulation. Samples are packed as:

```text
sample[31:16] = signed 16-bit real component
sample[15:0]  = signed 16-bit imaginary component
```

The default hardware build applies one arithmetic right shift per butterfly
stage (`FftScalingMode=1`). For the default 16-point build this gives an
overall scale of `1/16` relative to an unscaled DFT. The selected build options
are reported through the `CONFIG` register.

The top-level RTL parameters for the accelerator are:

| Parameter | Default | Description |
| --- | --- | --- |
| `FftLength` | `16` | complex samples per run |
| `FftDataWidth` | `16` | signed bits per real/imaginary component |
| `FftScalingMode` | `1` | `0`: no butterfly scaling, `1`: scale each stage |
| `FftInverse` | `0` | `0`: forward FFT, `1`: inverse FFT |
| `FftUseRounding` | `0` | `0`: truncate scaled results, `1`: round-half-up before shift |
| `FftUseSaturation` | `0` | `0`: wrap on overflow, `1`: saturate to signed min/max |

## Architecture

FFTodile keeps the original Croc split between the main SoC and the user domain.

![Croc block diagram](doc/croc_arch.svg)

Main blocks:

- `croc_domain`: CVE2 core, SRAM banks, debug module, main OBI interconnect, and basic peripherals
- `user_domain`: FFT accelerator, user ROM, and an error subordinate for unmapped accesses
- `fft_obi`: FFT control/status register bank, source/destination DMA, and completion interrupt
- `fft_core`: iterative radix-2 FFT datapath with local storage and one reused butterfly

The main interconnect protocol is OBI. The upstream OBI v1.6 specification is
available from OpenHW Group.

## Memory Map

The relevant default address ranges are:

| Start Address | End Address | Description |
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
| `0x2000_1000` | `...` | FFT accelerator registers |

FFT accelerator register map, relative to `FFT_BASE_ADDR = 0x2000_1000`:

| Offset | Register | Description |
| --- | --- | --- |
| `0x00` | `CTRL` | bit 0 starts one FFT run |
| `0x04` | `STATUS` | bit 0 busy, bit 1 sticky done; write 1 to done to clear |
| `0x08` | `SRC_ADDR` | source buffer address |
| `0x0C` | `DST_ADDR` | destination buffer address |
| `0x10` | `IRQ_CTRL` | bit 0 enables completion interrupt while done is set |
| `0x14` | `CONFIG` | synthesized FFT length, data width, scaling mode, and build flags |
| `0x18` | `CYCLES` | cycle count of the previous accelerator run |

`CONFIG` fields:

| Bits | Field | Description |
| --- | --- | --- |
| `[7:0]` | `LENGTH` | synthesized FFT length |
| `[11:8]` | `LOG2_LENGTH` | `log2(LENGTH)` |
| `[23:16]` | `DATA_WIDTH` | signed component width |
| `[24]` | `INVERSE` | inverse FFT build flag |
| `[26:25]` | `SCALE_MODE` | `0`: no butterfly scaling, `1`: scale each stage |
| `[27]` | `BIT_REVERSE` | input is loaded in bit-reversed order |

The user ROM returns the null-terminated chip ID string:

```text
FFTodile REV 1.0 - Flavian Kaufmann, Thanu Kanagalingam
```

## Repository Layout

```text
rtl/                  SystemVerilog RTL
rtl/user_domain/      FFTodile user-domain RTL
sw/                   Bare-metal software, tests, and benchmark
verilator/            Verilator simulation flow
yosys/                Synthesis flow
openroad/             Floorplan, placement, CTS, routing, finishing flow
klayout/              DEF-to-GDS, seal ring, fill flow
artistic/             GitHub Pages / mask-art rendering flow
ihp13/                IHP SG13G2 technology integration and PDK submodule
scripts/              Development-container, checks, and formatting helpers
doc/                  Documentation images
```

## Tool Environment

The intended development flow uses the `hpretl/iic-osic-tools:2025.12`
container through the repository scripts. Start an interactive development shell
with:

```sh
scripts/start_linux.sh
```

Inside that shell, use the top-level Makefile. The Docker container provides the
RISC-V toolchain, Verilator, Yosys, OpenROAD, KLayout, Bender, and the other
tools needed by the flow.

The PDK is a git submodule under `ihp13/pdk` and is patched by `env.sh` during
tool setup. If Git keeps reporting that submodule as dirty after the patch is
applied, this local setting is useful:

```sh
git config submodule.ihp13/pdk.ignore dirty
```

## Common Commands

Initialize submodules:

```sh
make init
```

Build all bare-metal software images:

```sh
make sw
```

Run the FFT correctness simulation:

```sh
make test-fft
```

To test an alternate Verilator compile-time FFT configuration, clean the
simulator and pass a top-level parameter override. For example, no butterfly
scaling:

```sh
make clean-sim
make test-fft VERILATOR_FLAGS=-GFftScalingMode=0

# Example: inverse FFT + rounding + saturation
make clean-sim
make test-fft \
  VERILATOR_FLAGS='-GFftInverse=1 -GFftUseRounding=1 -GFftUseSaturation=1' \
  RISCV_EXTRA_CCFLAGS='-DFFT_REF_USE_INVERSE=1 -DFFT_REF_USE_ROUNDING=1 -DFFT_REF_USE_SATURATION=1'

# Example: 8-point FFT build with matching software expectations
make clean-sim
make test-fft \
  VERILATOR_FLAGS='-GFftLength=8' \
  RISCV_EXTRA_CCFLAGS='-DFFT_SYNTH_LENGTH=8 -DFFT_SYNTH_LOG2_LENGTH=3'
```

The short CI flow runs a compact FFT matrix over representative build classes:
default 16-point, 8-point length, no-per-stage scaling, inverse mode, and a
combined rounding+saturation build. When adding a new FFT operating mode, add
at least one matching matrix entry so hardware parameters and software
reference-model flags stay aligned in CI.

Run the FFT benchmark simulation:

```sh
make bench-fft
```

The benchmark now runs repeated deterministic cases and reports min/median/max
cycle counts for software-visible runtime, accelerator runtime, and
transfer/host overhead for hardware runs. It emits both human-readable summary
lines and `BENCH_CSV,...` records that CI extracts into a CSV artifact.

Run a specific hex image in Verilator:

```sh
make sim BIN=sw/bin/test/test_fft.hex
```

Regenerate generated file lists:

```sh
make flist
```

Run synthesis:

```sh
make synth
```

Run the full OpenROAD backend after synthesis:

```sh
make backend
```

Generate and seal GDS:

```sh
make gds
make seal
```

Run the usual clean ASIC flow through sealed GDS:

```sh
make flow
```

Remove generated outputs:

```sh
make clean
```

Use `make help` for the full target list.

## Local Checks

Check Python and C/C++ formatting:

```sh
make lint
```

Apply formatting fixes:

```sh
make lint-fix
```

## Software Interface

The FFT software API is in `sw/lib/inc/fft.h`.

Typical use:

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

For test and benchmark reference calculations, `sw/lib/inc/fft_ref.h` contains a
small fixed-point software model that mirrors the hardware arithmetic.

The benchmark (`sw/benchmark_fft.c`) reports:

- software-visible cycle count for software FFT
- software-visible cycle count for hardware FFT
- accelerator-reported cycle count (`CYCLES` register)
- estimated transfer/host overhead (`software-visible - accelerator`)
- out-of-place and in-place hardware runs

## ASIC Flow

The top-level flow wraps the lower-level scripts:

```mermaid
graph LR;
  Bender-->Yosys;
  Yosys-->OpenROAD;
  OpenROAD-->KLayout;
```

The main stages are:

1. Bender/file lists define the RTL compilation order.
2. Yosys parses and maps RTL to the IHP SG13G2 standard-cell library.
3. OpenROAD performs floorplan, placement, CTS, routing, and finishing.
4. KLayout streams DEF to GDS, merges the seal ring, and can add fill.

Current layout snapshots:

| Module Placement | Routed Design |
| :---: | :---: |
| <img src="doc/fftodile_modules.jpg" alt="FFTodile module placement" width="420"> | <img src="doc/fftodile_routed.jpg" alt="FFTodile routed design" width="420"> |

Useful stage targets:

```sh
make synth
make floorplan
make placement
make cts
make routing
make finishing
make backend
make gds
make seal
make fill
```

Generated outputs are intentionally not tracked. Use the clean targets when
rerunning a stage from scratch:

```sh
make clean-synth
make clean-backend
make clean-gds
make clean-flow
```

## Artistic Flow

The `artistic/` directory contains the rendering flow used for GitHub Pages and
for previewing the top-metal artwork/map views. The artwork is for visualization
and mask-art generation; it is separate from the functional RTL.

Typical local sequence, split by environment:

On the host, with Inkscape/ImageMagick available:

```sh
cd artistic
./run_artistic.sh --prepare-logo
```

In the OSIC/OSEDA container:

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

Then open `http://localhost:8000` to inspect the generated map tiles.

## Configuration Notes

Main SoC configuration lives in `rtl/croc_pkg.sv`.

Software-visible platform constants in `sw/config.h` are generated from RTL by
`scripts/generate_sw_config.py` and refreshed automatically by `make sw`.
The canonical sources are:

- `rtl/croc_pkg.sv` for the main SoC and peripheral address map
- `rtl/user_pkg.sv` for user-domain address placement
- `rtl/test/tb_croc_pkg.sv` for testbench UART and clock defaults
- `rtl/croc_chip.sv` for the default FFT build parameters exposed to software

Important SRAM parameters:

- `NumSramBanks = 2`
- `SramBankNumWords = 1024`

The physical IHP SRAM mapping is implemented through `ihp13/tc_sram_impl.sv`.
The current `1024 x 32` logical SRAM bank maps to an IHP SRAM macro through that
technology wrapper.

User-domain address rules live in `rtl/user_pkg.sv`. The FFT accelerator is
currently mapped into the `UserDesign` region starting at `0x2000_1000`.

For non-default FFT simulations, keep the Verilator parameter override and the
software compile-time override aligned. For example, `VERILATOR_FLAGS='-GFftLength=8'`
still needs matching `RISCV_EXTRA_CCFLAGS='-DFFT_SYNTH_LENGTH=8 -DFFT_SYNTH_LOG2_LENGTH=3'`.

## Updating RTL Sources

When adding, removing, or moving RTL files:

1. Update `Bender.yml`.
2. Regenerate file lists with `make flist`, or update checked-in generated lists
   deliberately if you are avoiding Bender in a given environment.
3. Run at least `make test-fft`.
4. For synthesis-impacting changes, also run `make synth`.

## Guidelines

Use this checklist for changes that touch more than one surface.

SoC or address-map changes:

1. Edit the canonical RTL source: `rtl/croc_pkg.sv` for SoC/peripheral config,
  `rtl/user_pkg.sv` for user-domain placement, `rtl/test/tb_croc_pkg.sv` for
  testbench defaults.
2. Refresh software-visible constants with `make -C sw config` or any normal
  `make sw` / `make test-fft` run.
3. Run `make sim BIN=sw/bin/test/print_config.hex` and confirm the simulation
  exits successfully.
4. Update README text if the change is user-visible.

FFT operating-mode changes:

1. Keep hardware parameter changes and software reference-model macros aligned.
2. If you add a new default FFT parameter, update the RTL default in
  `rtl/croc_chip.sv` so the generated `sw/config.h` stays correct.
3. If you add a new non-default FFT mode, add a representative CI matrix entry
  in `.github/workflows/short-flow.yml` and make sure the matching software
  flags are passed to `test_fft.c`.
4. Run `make clean-sw clean-sim && make test-fft` for the default build, plus a
  matching overridden command for each newly supported variant.

CI and generated files:

1. Do not edit `sw/config.h` by hand; it is generated by
  `scripts/generate_sw_config.py`.
2. Regenerate file lists with `make flist` only when RTL source membership or
  ordering changes.
3. Do not check in generated logs, reports, Verilator build outputs, or OpenROAD
  outputs.
4. If a change adds or removes a user-facing command, CI job, or validation
  expectation, update README and the relevant workflow/script in the same
  change.

Expected validation baseline:

1. Formatting-only changes: `make lint`
2. FFT datapath or software-model changes: `make test-fft`
3. SoC/config/introspection changes: `make sim BIN=sw/bin/test/print_config.hex`
4. Synthesis-impacting RTL changes: `make synth`

## Upstream Context

This repository is based on Croc, an educational SoC developed as part of the
PULP project by ETH Zurich and the University of Bologna. Croc includes a small
CVE2-based SoC and scripts for IHP SG13G2-based chip implementation. FFTodile
keeps that infrastructure and replaces the generic user-design area with the FFT
accelerator project.

## License

Unless specified otherwise in individual file headers, hardware sources and tool
scripts are licensed under the Solderpad Hardware License 0.51. Software sources
are licensed under Apache 2.0. See `LICENSE.md` and file headers for details.
