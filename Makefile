# Groovy_Tang simulation build
# Requires Icarus Verilog (iverilog/vvp) and Verilator. No vendor toolchain needed.
#
#   make test                       run all self-checking testbenches
#   make <tbname>                   run one testbench (e.g. make groovy_pll_solver_tb)
#   make wave TB=<tbname>           build + run with VCD dump -> sim/build/wave.vcd
#   make test-gwline                full-top benches of gwline (Verilator, several minutes)
#   make clean

IVERILOG ?= iverilog
VVP      ?= vvp

TB_DIR := sim/tb
BUILD  := sim/build

# -y library dirs: iverilog auto-loads <modulename>.v on demand, so only the
# modules a testbench actually instantiates get compiled (stubs stay out).
LIBDIRS := -y rtl/core \
           -y rtl/generic/video -y rtl/generic/compression \
           -y rtl/vendor/gowin
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

# Full-top benches of the release design (gwline_top + the real udp.sv over RMII), fed
# by tools/gen_gwline_stream.py. Several minutes each, so not part of `make test`.
#   gwline_top_e2e_tb   VIDEO_MODE 0 (720p): every output pixel checked, 4 frames
#   gwline_modeline_tb  VIDEO_MODE 4: the raster follows three modelines (240p, 448i,
#                       384x224), raw RGB565 then QOI per line, ring purged at CMD_CLOSE
GW_SRC := rtl/vendor/sipeed_udp/udp.sv \
          $(addprefix rtl/core/,groovy_packet_parser.v groovy_session.v groovy_ack_policy.v \
            groovy_ack_sender.v groovy_features.v groovy_switchres.v groovy_pll_solver.v \
            pclk_double_to_khz.v groovy_tx_arbiter.v groovy_beacon_sender.v groovy_blit_rx.v \
            groovy_qoi_rx.v groovy_ring_stats.v groovy_udp_rx_framer.v groovy_audio.v \
            groovy_linering.v groovy_linewr.v groovy_linescan.v groovy_lineram.v \
            groovy_slotline_ram.v groovy_modeline_ctl.v) \
          rtl/generic/video/superres_factor.v rtl/generic/compression/qoi_line_decoder.v \
          rtl/vendor/gowin/rpll_sel_encode.v rtl/generic/video/video_timing_gen_il.v \
          rtl/vendor/nand2mario_ddr3/uart_tx_V2.v rtl/board/tang_primer_20k/gwline/gwline_top.sv \
          sim/tb/gwline_sim_stubs.sv
GW_MODES := 6.7,320,352,383,430,240,241,244,262,0;6.7,320,352,383,430,448,465,471,525,1;8.0,384,422,459,515,224,232,235,261,0
GW_GM    := --groovymame --rgb565 --frames 3 --lines-per-dgram 1

$(BUILD)/V%: sim/tb/%.sv $(GW_SRC) | $(BUILD)
	@echo "== build $* (verilator) =="
	@$(VERILATOR) --binary --timing --bbox-unsup -Wno-fatal -Wno-lint -Wno-style \
	    +incdir+rtl/vendor/sipeed_udp --top-module $* -Mdir $(BUILD)/obj_$* -o $(abspath $@) \
	    $(GW_SRC) $< > $(BUILD)/$*.vbuild.log 2>&1 || (grep %Error $(BUILD)/$*.vbuild.log; exit 1)

.PHONY: test-gwline
test-gwline: $(BUILD)/Vgwline_top_e2e_tb $(BUILD)/Vgwline_modeline_tb
	@python3 tools/gen_gwline_stream.py $(BUILD)/gw_e2e --frames 4 > /dev/null
	@python3 tools/gen_gwline_stream.py $(BUILD)/gw_raw --modes "$(GW_MODES)" $(GW_GM) > /dev/null
	@python3 tools/gen_gwline_stream.py $(BUILD)/gw_qoi --modes "$(GW_MODES)" $(GW_GM) --qoi > /dev/null
	@echo "== run gwline_top_e2e_tb ==";  $(BUILD)/Vgwline_top_e2e_tb +DIR=$(BUILD)/gw_e2e +LEAD=16
	@echo "== run gwline_modeline_tb (raw) =="; $(BUILD)/Vgwline_modeline_tb +DIR=$(BUILD)/gw_raw +SEGS=3
	@echo "== run gwline_modeline_tb (QOI) =="; $(BUILD)/Vgwline_modeline_tb +DIR=$(BUILD)/gw_qoi +SEGS=3 +QOI

wave: | $(BUILD)
	@test -n "$(TB)" || (echo "usage: make wave TB=<tbname>"; exit 1)
	@$(IVERILOG) $(IFLAGS) -DDUMP -o $(BUILD)/$(TB).vvp -s $(TB) $(TB_DIR)/$(TB).v
	@$(VVP) $(BUILD)/$(TB).vvp
	@echo "VCD written to sim/build/wave.vcd"

$(BUILD):
	@mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)
