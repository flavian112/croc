SHELL := /bin/bash

PROJ_NAME ?= croc
TOP_DESIGN ?= croc_chip
BIN ?= sw/bin/helloworld.hex

RUN_ENV := PROJ_NAME="$(PROJ_NAME)" TOP_DESIGN="$(TOP_DESIGN)"

.DEFAULT_GOAL := help

.PHONY: all help init submodules shell vnc flist flist-yosys flist-verilator flist-vsim \
	flist-xilinx sw sim sim-ci sim-verilator sim-vsim verilator-build verilator-run vsim-build \
	vsim-build-netlist vsim-run vsim-run-gui synth synth-ci backend backend-floorplan \
	backend-placement backend-cts backend-routing backend-finishing drc gds seal \
	fill-metal fill-activ fill asic asic-ci asic-sealed asic-filled clean clean-sw \
	clean-verilator clean-openroad clean-klayout

all: asic

help:
	@printf '%s\n' \
	  'Croc top-level build targets' \
	  '' \
	  'Setup:' \
	  '  make init              Initialize git submodules' \
	  '  make shell             Start the OSIC tools shell helper' \
	  '  make vnc               Start the OSIC tools VNC helper' \
	  '' \
	  'File lists:' \
	  '  make flist             Regenerate Yosys, Verilator, and VSIM file lists' \
	  '  make flist-xilinx      Regenerate Vivado source script' \
	  '' \
	  'ASIC flow:' \
	  '  make synth             Run Yosys synthesis' \
	  '  make synth-ci          Run the same two-phase synthesis helper used by GitHub Actions' \
	  '  make backend           Run OpenROAD stages 01-05' \
	  '  make drc               Run routing stage and write the detailed-route DRC report' \
	  '  make gds               Convert final DEF to GDS with KLayout' \
	  '  make seal              Add the seal ring to the GDS' \
	  '  make fill-metal        Add metal fill to the sealed GDS' \
	  '  make fill              Add metal and active fill to the sealed GDS' \
	  '  make asic              Run the same full ASIC helper used by GitHub Actions' \
	  '  make asic-ci           Alias of make asic' \
	  '  make asic-sealed       Run synth + backend + gds + seal' \
	  '  make asic-filled       Run synth + backend + gds + seal + fill' \
	  '' \
	  'Simulation:' \
	  '  make sw                Build software images in sw/' \
	  '  make sim               Build software, Verilator, and run BIN=$(BIN)' \
	  '  make sim-ci            Run the same two-phase simulation helper used by GitHub Actions' \
	  '  make sim-vsim          Build software, VSIM RTL, and run BIN=$(BIN)' \
	  '' \
	  'Overrides:' \
	  '  make <target> PROJ_NAME=test TOP_DESIGN=my_chip BIN=sw/bin/other.hex' \
	  '' \
	  'Note: run the ASIC targets inside the supported Linux or OSIC-tools container environment.'

init: submodules

submodules:
	git submodule update --init --recursive

shell:
	./scripts/start_linux.sh

vnc:
	./scripts/start_vnc.sh

flist: flist-yosys flist-verilator flist-vsim

flist-yosys:
	cd yosys && $(RUN_ENV) ./run_synthesis.sh --flist

flist-verilator:
	cd verilator && $(RUN_ENV) ./run_verilator.sh --flist

flist-vsim:
	cd vsim && $(RUN_ENV) ./run_vsim.sh --flist

flist-xilinx:
	cd xilinx && $(RUN_ENV) ./run_xilinx.sh --flist

sw:
	$(MAKE) -C sw all

verilator-build:
	cd verilator && $(RUN_ENV) ./run_verilator.sh --build

verilator-run:
	cd verilator && $(RUN_ENV) ./run_verilator.sh --run ../$(BIN)

sim-verilator: sw verilator-build verilator-run

sim: sim-verilator

sim-ci:
	$(RUN_ENV) ./.github/scripts/run_sim_flow.sh

vsim-build:
	cd vsim && $(RUN_ENV) ./run_vsim.sh --build

vsim-build-netlist:
	cd vsim && $(RUN_ENV) ./run_vsim.sh --build-netlist

vsim-run:
	cd vsim && $(RUN_ENV) ./run_vsim.sh --run ../$(BIN)

vsim-run-gui:
	cd vsim && $(RUN_ENV) ./run_vsim.sh --run-gui ../$(BIN)

sim-vsim: sw vsim-build vsim-run

synth:
	cd yosys && $(RUN_ENV) ./run_synthesis.sh --synth

synth-ci:
	$(RUN_ENV) ./.github/scripts/run_synth_flow.sh

backend-floorplan:
	cd openroad && $(RUN_ENV) ./run_backend.sh --floorplan

backend-placement:
	cd openroad && $(RUN_ENV) ./run_backend.sh --placement

backend-cts:
	cd openroad && $(RUN_ENV) ./run_backend.sh --cts

backend-routing:
	cd openroad && $(RUN_ENV) ./run_backend.sh --routing
	@printf '%s\n' 'Detailed-route DRC report: openroad/reports/04_$(PROJ_NAME)_route_drc.rpt'

drc: backend-routing

backend-finishing:
	cd openroad && $(RUN_ENV) ./run_backend.sh --finishing

backend:
	cd openroad && $(RUN_ENV) ./run_backend.sh --all

gds:
	cd klayout && $(RUN_ENV) ./run_finishing.sh --gds

seal: gds
	cd klayout && $(RUN_ENV) ./run_finishing.sh --seal

fill-metal: seal
	cd klayout && $(RUN_ENV) ./run_finishing.sh --fill-metal

fill-activ: fill-metal
	cd klayout && $(RUN_ENV) ./run_finishing.sh --fill-activ

fill: seal
	cd klayout && $(RUN_ENV) ./run_finishing.sh --fill

asic: asic-ci

asic-ci:
	$(RUN_ENV) ./.github/scripts/run_full_flow.sh

asic-sealed: synth backend seal

asic-filled: synth backend fill

clean: clean-sw clean-verilator clean-openroad clean-klayout

clean-sw:
	$(MAKE) -C sw clean

clean-verilator:
	rm -rf verilator/obj_dir verilator/*.log verilator/croc.f

clean-openroad:
	rm -rf openroad/logs openroad/out openroad/reports openroad/save

clean-klayout:
	rm -rf klayout/out