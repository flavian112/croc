SHELL := /bin/bash

.DEFAULT_GOAL := help

# -----------------------------------------------------------------------------
# User configuration
# -----------------------------------------------------------------------------

PROJ_NAME  ?= croc
TOP_DESIGN ?= croc_chip
BIN        ?= sw/bin/helloworld.hex
VERILATOR_FLAGS ?=

export PROJ_NAME
export TOP_DESIGN
export VERILATOR_FLAGS

RMDIR := rm -rf

# -----------------------------------------------------------------------------
# Tool entry points
# -----------------------------------------------------------------------------

YOSYS      := cd yosys && ./run_synthesis.sh
VERILATOR  := cd verilator && ./run_verilator.sh
VSIM       := cd vsim && ./run_vsim.sh
OPENROAD   := cd openroad && ./run_backend.sh
KLAYOUT    := cd klayout && ./run_finishing.sh

# -----------------------------------------------------------------------------
# Phony targets
# -----------------------------------------------------------------------------

.PHONY: help init
.PHONY: sw
.PHONY: format format-cxx format-python format-check format-check-cxx format-check-python
.PHONY: format-cxx-ci format-check-cxx-ci
.PHONY: sim sim-build sim-run test-fft bench-fft test-sram
.PHONY: flist flist-yosys flist-verilator flist-vsim
.PHONY: synth
.PHONY: floorplan placement cts routing finishing backend
.PHONY: gds seal fill
.PHONY: flow clean-flow flow-clean
.PHONY: clean clean-sw clean-sim clean-synth clean-backend clean-gds

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------

help:
	@printf '%s\n' \
		'Usage: make <target> [VARIABLE=value]' \
		'' \
		'Common variables:' \
		'  PROJ_NAME   Project/output name        (default: croc)' \
		'  TOP_DESIGN  Top-level RTL module       (default: croc_chip)' \
		'  BIN         Hex image for simulation   (default: sw/bin/helloworld.hex)' \
		'  VERILATOR_FLAGS Extra Verilator args   (default: empty)' \
		'' \
		'Setup:' \
		'  init              Initialize git submodules' \
		'' \
		'Software and simulation:' \
		'  sw                Build all software images in sw/' \
		'  format            Apply C/C++ and Python formatting (sw + klayout/scripts)' \
		'  format-check      Check C/C++ and Python formatting (CI-equivalent scope)' \
		'  format-cxx-ci     Apply C/C++ formatting using clang-format-17 in Ubuntu container' \
		'  format-check-cxx-ci Check C/C++ formatting using clang-format-17 in Ubuntu container' \
		'  sim               Build software, build Verilator, and run BIN' \
		'  test-fft          Simulate the FFT correctness test' \
		'  test-sram         Simulate the SRAM address/data test' \
		'  bench-fft         Simulate the FFT benchmark' \
		'  sim-build         Build the Verilator simulator only' \
		'  sim-run           Run BIN on an already-built Verilator simulator' \
		'' \
		'File lists:' \
		'  flist             Regenerate all generated file lists' \
		'  flist-yosys       Regenerate yosys/src/croc.flist' \
		'  flist-verilator   Regenerate verilator/croc.f' \
		'  flist-vsim        Regenerate the Questa/VSIM file list' \
		'' \
		'ASIC flow:' \
		'  synth             Run Yosys synthesis' \
		'  floorplan         Run OpenROAD stage 01' \
		'  placement         Run OpenROAD stage 02' \
		'  cts               Run OpenROAD stage 03' \
		'  routing           Run OpenROAD stage 04' \
		'  finishing         Run OpenROAD stage 05' \
		'  backend           Run all OpenROAD stages' \
		'  gds               Convert routed DEF to GDS' \
		'  seal              Generate and merge the seal ring' \
		'  fill              Add metal and active fill' \
		'  flow              Clean ASIC outputs, then run synth/backend/gds/seal' \
		'' \
		'Clean:' \
		'  clean             Remove all generated outputs' \
		'  clean-flow        Remove generated ASIC flow outputs' \
		'  clean-sw          Remove software build outputs' \
		'  clean-sim         Remove Verilator build/run outputs' \
		'  clean-synth       Remove Yosys outputs' \
		'  clean-backend     Remove OpenROAD outputs' \
		'  clean-gds         Remove KLayout outputs' \
		'' \
		'Examples:' \
		'  make test-fft' \
		'  make sim BIN=sw/bin/test/test_fft.hex' \
		'  make flow PROJ_NAME=croc TOP_DESIGN=croc_chip'

# -----------------------------------------------------------------------------
# Setup
# -----------------------------------------------------------------------------

init:
	git submodule update --init --recursive

# -----------------------------------------------------------------------------
# Software and simulation
# -----------------------------------------------------------------------------

sw:
	$(MAKE) -C sw all

format-cxx:
	docker run --rm -v $(CURDIR):/work ubuntu:24.04 bash -lc "apt-get update >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y python3 clang-format-17 >/dev/null && cd /work && python3 scripts/run_clang_format.py -ir sw --extensions c,h,cpp --clang-format-executable=clang-format-17"

sim: sw sim-build sim-run

sim-build:
	$(VERILATOR) --build

sim-run:
	$(VERILATOR) --run ../$(BIN)

test-fft: BIN := sw/bin/test/test_fft.hex
test-fft: sim

bench-fft: BIN := sw/bin/benchmark_fft.hex
bench-fft: sim

test-sram: BIN := sw/bin/test/test_sram.hex
test-sram: sim

# -----------------------------------------------------------------------------
# File lists
# -----------------------------------------------------------------------------

flist: flist-yosys flist-verilator flist-vsim

flist-yosys:
	$(YOSYS) --flist

flist-verilator:
	$(VERILATOR) --flist

flist-vsim:
	$(VSIM) --flist

# -----------------------------------------------------------------------------
# ASIC flow
# -----------------------------------------------------------------------------

synth:
	$(YOSYS) --synth

floorplan:
	$(OPENROAD) --floorplan

placement:
	$(OPENROAD) --placement

cts:
	$(OPENROAD) --cts

routing:
	$(OPENROAD) --routing

finishing:
	$(OPENROAD) --finishing

backend:
	$(OPENROAD) --all

gds:
	$(KLAYOUT) --gds

seal:
	$(KLAYOUT) --seal

fill:
	$(KLAYOUT) --fill

flow: clean-flow synth backend gds seal

flow-clean: flow

# -----------------------------------------------------------------------------
# Clean
# -----------------------------------------------------------------------------

clean: clean-sw clean-sim clean-flow

clean-flow: clean-synth clean-backend clean-gds

clean-sw:
	$(MAKE) -C sw clean

clean-sim:
	$(RMDIR) verilator/obj_dir
	$(RMDIR) verilator/*.log
	$(RMDIR) verilator/*.fst
	$(RMDIR) verilator/croc_build.log

clean-synth:
	$(RMDIR) yosys/out
	$(RMDIR) yosys/reports
	$(RMDIR) yosys/tmp
	$(RMDIR) yosys/croc.log

clean-backend:
	$(RMDIR) openroad/logs
	$(RMDIR) openroad/save
	$(RMDIR) openroad/reports
	$(RMDIR) openroad/out

clean-gds:
	$(RMDIR) klayout/out
