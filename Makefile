SHELL := /bin/bash

.DEFAULT_GOAL := help

PROJ_NAME       ?= croc
TOP_DESIGN      ?= croc_chip
BIN             ?= sw/bin/helloworld.hex
VERILATOR_FLAGS ?=

export PROJ_NAME TOP_DESIGN VERILATOR_FLAGS

YOSYS     := cd yosys && ./run_synthesis.sh
VERILATOR := cd verilator && ./run_verilator.sh
VSIM      := cd vsim && ./run_vsim.sh
OPENROAD  := cd openroad && ./run_backend.sh
KLAYOUT   := cd klayout && ./run_finishing.sh

CLANG_FORMAT_ARGS := -r sw --extensions c,h,cpp --clang-format-executable=clang-format-17

.PHONY: help init sw lint lint-fix
.PHONY: sim sim-build sim-run test-fft bench-fft test-sram flist
.PHONY: synth floorplan placement cts routing finishing backend gds seal fill flow
.PHONY: clean clean-sw clean-sim clean-flow

help:
	@printf '%s\n' \
		'Usage: make <target> [VARIABLE=value]' \
		'Variables: PROJ_NAME, TOP_DESIGN, BIN, VERILATOR_FLAGS' \
		'' \
		'  init          Initialize git submodules' \
		'  sw            Build all software images' \
		'  lint          Check Python and C/C++ formatting' \
		'  lint-fix      Apply formatting fixes' \
		'  sim           Build software, Verilator, and run BIN' \
		'  test-fft      Simulate the FFT correctness test' \
		'  bench-fft     Simulate the FFT benchmark' \
		'  test-sram     Simulate the SRAM address/data test' \
		'  synth         Run Yosys synthesis' \
		'  backend       Run all OpenROAD stages' \
		'  gds / seal    GDS conversion and seal ring' \
		'  flow          Clean then run synth/backend/gds/seal' \
		'  flist         Regenerate all generated file lists' \
		'  clean         Remove all generated outputs' \
		'' \
		'Examples:' \
		'  make test-fft' \
		'  make sim BIN=sw/bin/test/test_fft.hex' \
		'  make flow PROJ_NAME=croc TOP_DESIGN=croc_chip'

init:
	git submodule update --init --recursive

sw:
	$(MAKE) -C sw all

lint:
	black klayout/scripts --check
	python3 scripts/run_clang_format.py $(CLANG_FORMAT_ARGS)

lint-fix:
	black klayout/scripts
	python3 scripts/run_clang_format.py -i $(CLANG_FORMAT_ARGS)

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

flist:
	$(YOSYS) --flist
	$(VERILATOR) --flist
	$(VSIM) --flist

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

flow: synth backend gds seal

clean: clean-sw clean-sim clean-flow

clean-flow:
	rm -rf yosys/out yosys/reports yosys/tmp yosys/croc.log
	rm -rf openroad/logs openroad/save openroad/reports openroad/out
	rm -rf klayout/out

clean-sw:
	$(MAKE) -C sw clean

clean-sim:
	rm -rf verilator/obj_dir verilator/*.log verilator/*.fst verilator/croc_build.log
