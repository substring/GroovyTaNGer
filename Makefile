# Groovy_Tang simulation build
# Requires Icarus Verilog (iverilog/vvp). No vendor toolchain needed.
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

TESTS := $(notdir $(basename $(wildcard $(TB_DIR)/*_tb.v)))

.PHONY: test clean wave $(TESTS)

test: $(TESTS)
	@echo "================================================"
	@echo "All testbenches completed."

$(TESTS): %: | $(BUILD)
	@echo "== build+run $@ =="
	@$(IVERILOG) $(IFLAGS) -o $(BUILD)/$@.vvp -s $@ $(TB_DIR)/$@.v
	@$(VVP) $(BUILD)/$@.vvp

wave: | $(BUILD)
	@test -n "$(TB)" || (echo "usage: make wave TB=<tbname>"; exit 1)
	@$(IVERILOG) $(IFLAGS) -DDUMP -o $(BUILD)/$(TB).vvp -s $(TB) $(TB_DIR)/$(TB).v
	@$(VVP) $(BUILD)/$(TB).vvp
	@echo "VCD written to sim/build/wave.vcd"

$(BUILD):
	@mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)
