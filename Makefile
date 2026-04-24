SHELL := /bin/bash

PROJ_NAME  ?= croc
TOP_DESIGN ?= croc_chip
BIN        ?= sw/bin/helloworld.hex

RUN_ENV := PROJ_NAME="$(PROJ_NAME)" TOP_DESIGN="$(TOP_DESIGN)"

.DEFAULT_GOAL := help

.PHONY: help init sw sim \
        flist flist-yosys flist-verilator flist-vsim \
        synth \
        floorplan placement cts routing finishing backend \
        gds seal fill \
        flow clean-flow flow-clean \
        clean clean-sw clean-sim clean-synth clean-backend clean-gds

# ------------------------------------------------------------------------------
# Help
# ------------------------------------------------------------------------------
help:
	@printf '%s\n' \
	  'Usage: make <target>' \
	  '' \
	  'Setup' \
	  '  init          Initialize git submodules' \
	  '' \
	  'Software' \
	  '  sw            Build all SW images in sw/' \
	  '  sim           Build SW + Verilator and run BIN=$(BIN)' \
	  '' \
	  'File lists (regenerate)' \
	  '  flist         Yosys + Verilator + VSIM file lists' \
	  '  flist-yosys   Yosys file list only' \
	  '  flist-verilator Verilator file list only' \
	  '  flist-vsim    VSIM file list only' \
	  '' \
	  'ASIC - individual steps' \
	  '  synth         Yosys synthesis' \
	  '  floorplan     OpenROAD stage 01 (floorplan + power grid)' \
	  '  placement     OpenROAD stage 02 (placement)' \
	  '  cts           OpenROAD stage 03 (clock tree)' \
	  '  routing       OpenROAD stage 04 (routing)' \
	  '  finishing     OpenROAD stage 05 (fill + outputs)' \
	  '  backend       OpenROAD stages 01-05 (full P&R)' \
	  '  gds           KLayout: DEF to GDS' \
	  '  seal          KLayout: merge seal ring' \
	  '  fill          KLayout: metal + active fill' \
	  '' \
	  'ASIC - full flows' \
	  '  flow          Clean + synth + backend + gds + seal  (recommended)' \
	  '  flow-clean    Alias for flow (clean is always done first)' \
	  '' \
	  'Clean' \
	  '  clean         Remove all generated outputs' \
	  '  clean-synth   Remove Yosys outputs only' \
	  '  clean-backend Remove OpenROAD outputs only' \
	  '  clean-gds     Remove KLayout outputs only' \
	  '' \
	  'Overrides: make <target> PROJ_NAME=croc TOP_DESIGN=croc_chip BIN=sw/bin/other.hex'

# ------------------------------------------------------------------------------
# Setup
# ------------------------------------------------------------------------------
init:
	git submodule update --init --recursive

# ------------------------------------------------------------------------------
# Software
# ------------------------------------------------------------------------------
sw:
	$(MAKE) -C sw all

sim: sw
	cd verilator && $(RUN_ENV) ./run_verilator.sh --build
	cd verilator && $(RUN_ENV) ./run_verilator.sh --run ../$(BIN)

# ------------------------------------------------------------------------------
# File lists
# ------------------------------------------------------------------------------
flist: flist-yosys flist-verilator flist-vsim

flist-yosys:
	cd yosys && $(RUN_ENV) ./run_synthesis.sh --flist

flist-verilator:
	cd verilator && $(RUN_ENV) ./run_verilator.sh --flist

flist-vsim:
	cd vsim && $(RUN_ENV) ./run_vsim.sh --flist

# ------------------------------------------------------------------------------
# ASIC - individual steps
# ------------------------------------------------------------------------------
synth:
	cd yosys && $(RUN_ENV) ./run_synthesis.sh --synth

floorplan:
	cd openroad && $(RUN_ENV) ./run_backend.sh --floorplan

placement:
	cd openroad && $(RUN_ENV) ./run_backend.sh --placement

cts:
	cd openroad && $(RUN_ENV) ./run_backend.sh --cts

routing:
	cd openroad && $(RUN_ENV) ./run_backend.sh --routing

finishing:
	cd openroad && $(RUN_ENV) ./run_backend.sh --finishing

backend:
	cd openroad && $(RUN_ENV) ./run_backend.sh --all

gds:
	cd klayout && $(RUN_ENV) ./run_finishing.sh --gds

seal:
	cd klayout && $(RUN_ENV) ./run_finishing.sh --seal

fill:
	cd klayout && $(RUN_ENV) ./run_finishing.sh --fill

# ------------------------------------------------------------------------------
# ASIC - full flows
# ------------------------------------------------------------------------------
flow: clean-synth clean-backend clean-gds synth backend gds seal

flow-clean: flow

# ------------------------------------------------------------------------------
# Clean
# ------------------------------------------------------------------------------
clean: clean-sw clean-sim clean-synth clean-backend clean-gds

clean-sw:
	$(MAKE) -C sw clean

clean-sim:
	rm -rf verilator/obj_dir verilator/*.log verilator/*.fst verilator/croc_build.log

clean-synth:
	rm -rf yosys/out yosys/reports yosys/tmp yosys/croc.log

clean-backend:
	rm -rf openroad/logs openroad/save openroad/reports openroad/out

clean-gds:
	rm -rf klayout/out