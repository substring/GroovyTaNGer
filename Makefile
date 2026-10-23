# Groovy_Tang simulation build
# Requires Icarus Verilog (iverilog/vvp) and Verilator. No vendor toolchain needed.
#
#   make test                       run all self-checking testbenches
#   make <tbname>                   run one testbench (e.g. make groovy_pll_solver_tb)
#   make wave TB=<tbname>           build + run with VCD dump -> sim/build/wave.vcd
#   make clean

IVERILOG ?= iverilog
VVP      ?= vvp

TB_DIR := sim/tb
BUILD  := sim/build

# -y library dirs: iverilog auto-loads <modulename>.v on demand, so only the
# modules a testbench actually instantiates get compiled (stubs stay out).
LIBDIRS := -y rtl/core \
           -y rtl/generic -y rtl/generic/video -y rtl/generic/math \
           -y rtl/generic/compression -y rtl/generic/memory \
           -y rtl/generic/ethernet -y rtl/generic/audio \
           -y rtl/vendor/gowin \
           -y rtl/board/tang_primer_20k/bringup
IFLAGS := -g2012 -Wall $(LIBDIRS)

# Benches that instantiate the vendored udp.sv: it uses SystemVerilog interfaces
# (rmii.svh) that Icarus cannot parse, so they are built with Verilator instead.
VERILATOR ?= verilator
VFLAGS    := --binary --timing --bbox-unsup -Wno-fatal -Wno-lint -Wno-style \
             -Irtl/vendor/sipeed_udp
UDP_TESTS := udp_ifg_sweep_tb groovy_udpstress_udpsv_realframe_tb

ALL_TESTS := $(notdir $(basename $(wildcard $(TB_DIR)/*_tb.v)))
TESTS     := $(filter-out $(UDP_TESTS),$(ALL_TESTS))

.PHONY: test clean wave $(TESTS) $(UDP_TESTS)

test: $(TESTS) $(UDP_TESTS)
	@echo "================================================"
	@echo "All testbenches completed."

$(TESTS): %: | $(BUILD)
	@echo "== build+run $@ =="
	@$(IVERILOG) $(IFLAGS) -o $(BUILD)/$@.vvp -s $@ $(TB_DIR)/$@.v
	@$(VVP) $(BUILD)/$@.vvp

$(UDP_TESTS): %: | $(BUILD)
	@echo "== build+run $@ (verilator) =="
	@$(VERILATOR) $(VFLAGS) --top-module $@ -Mdir $(BUILD)/obj_$@ -o $@ \
	    $(TB_DIR)/$@.v rtl/vendor/sipeed_udp/udp.sv > $(BUILD)/$@.vbuild.log 2>&1 \
	    || (cat $(BUILD)/$@.vbuild.log; exit 1)
	@$(BUILD)/obj_$@/$@

wave: | $(BUILD)
	@test -n "$(TB)" || (echo "usage: make wave TB=<tbname>"; exit 1)
	@$(IVERILOG) $(IFLAGS) -DDUMP -o $(BUILD)/$(TB).vvp -s $(TB) $(TB_DIR)/$(TB).v
	@$(VVP) $(BUILD)/$(TB).vvp
	@echo "VCD written to sim/build/wave.vcd"

$(BUILD):
	@mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)
