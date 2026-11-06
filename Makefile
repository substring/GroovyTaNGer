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

# Benches whose vectors come from a C golden model (tools/qoiline), built with $(CC).
CC      ?= gcc
QOI_DIR := tools/qoiline
QOI_REF ?= $(firstword $(wildcard $(HOME)/git/SDL_image/src/qoi.h))
C_TESTS := qoi_line_decoder_tb

ALL_TESTS := $(notdir $(basename $(wildcard $(TB_DIR)/*_tb.v)))
TESTS     := $(filter-out $(UDP_TESTS) $(C_TESTS),$(ALL_TESTS))

.PHONY: test clean wave qoiline_test $(TESTS) $(UDP_TESTS) $(C_TESTS)

test: qoiline_test $(TESTS) $(UDP_TESTS) $(C_TESTS)
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

# C reference self-test; with a reference qoi.h (QOI_REF=path, MIT, phoboslab) it also
# checks RGB888 lines against standard QOI byte for byte
$(BUILD)/qoiline_test: $(QOI_DIR)/qoiline_test.c $(QOI_DIR)/qoiline.c $(QOI_DIR)/qoiline.h | $(BUILD)
	@$(CC) -std=c99 -O2 -Wall -Wextra -pedantic \
	    $(if $(QOI_REF),-DQOI_REF_H='"$(abspath $(QOI_REF))"') \
	    -o $@ $(QOI_DIR)/qoiline_test.c $(QOI_DIR)/qoiline.c

# the GroovyMAME patch carries a copy of qoiline.h: it must stay the same file
QOI_PATCH := patches/groovymame-mister-qoi.patch
qoiline_test: $(BUILD)/qoiline_test
	@echo "== run qoiline_test (C reference) =="
	@$(BUILD)/qoiline_test
	@awk '/^\+\+\+ b\/src\/osd\/modules\/render\/qoiline.h/{f=1;getline;next} f&&/^diff /{f=0} \
	    f&&/^\+/{print substr($$0,2)}' $(QOI_PATCH) | cmp -s - $(QOI_DIR)/qoiline.h \
	    && echo "qoiline.h in $(QOI_PATCH): in sync" \
	    || (echo "FAIL: qoiline.h in $(QOI_PATCH) differs from $(QOI_DIR)/qoiline.h"; exit 1)

qoi_line_decoder_tb: $(BUILD)/qoiline_test
	@echo "== build+run $@ (vectors from tools/qoiline) =="
	@mkdir -p $(BUILD)/qoiline
	@$(BUILD)/qoiline_test --vectors $(BUILD)/qoiline
	@$(IVERILOG) $(IFLAGS) -DVDIR='"$(BUILD)/qoiline"' -o $(BUILD)/$@.vvp -s $@ $(TB_DIR)/$@.v
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
