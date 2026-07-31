// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - ISOLATED UDP stack stress test (2026-07-19).
//
// PURPOSE: measure whether the vendored Sipeed UDP stack (udp.sv) drops packets under
// sustained load, INDEPENDENTLY of the rest of the beam-race pipeline (blit_rx, the
// sync FIFO, the ring buffer, the lap-guard). This session spent a long time debugging
// RD (network frame completion count) stalling despite zero detected timeouts/rejects
// at every layer we could instrument from INSIDE the pipeline - this target answers the
// question "is the raw UDP receive path itself lossy?" with nothing else in the way.
//
// PROTOCOL: the PC sender puts a 32-bit sequence number (little-endian) as the FIRST 4
// bytes of every UDP payload, counting 0, 1, 2, ... continuously across all packets of
// a run (not per-frame - one long counter for the whole test). Payload is padded to
// 1280 bytes total (matching our real per-datagram size: 2 lines x 320px x 2B RGB565),
// but only the first 4 bytes are read.
//
// DETECTION: this top does NOT use groovy_packet_parser/groovy_session at all - it
// reads udp.sv's raw rx_data byte stream directly, waiting for exactly 4 bytes after
// each UDP frame boundary (rx_head_av pulses once per frame; we resync at every one)
// and comparing the decoded sequence number against next_expected. A gap increments
// gap_count by (received - expected); a corrupt/backwards value the correctly-flowing
// state won't produce is otherwise divergence-tolerant (resyncs to whatever it saw).
//
// UART report (same 115200 8N1 framing as gwline's debug UART): a repeating text line
//   RX=xxxxxxxx GAP=xxxxxxxx LAST=xxxxxxxx
// RX = cumulative packets seen with a valid 4-byte seq prefix. GAP = cumulative total
// of missed sequence numbers (sum of every gap's size, not just gap COUNT - so losing
// 5 in a row and losing 1 five separate times both read as GAP=5, a byte-accurate loss
// tally). LAST = the most recently seen sequence number (proves liveness / where a run
// stopped).
`include "rmii.svh"

module groovy_udpstress_top (
    input  clk,        // 27 MHz, H11
    input  rst,        // active-low button, T10
    rmii   netrmii,
    output phyrst,
    output [5:0] led,
    output uart_txp
);
    localparam [15:0] OUR_PORT = 16'd32100;

    logic [23:0] ckdiv;
    always_ff @(posedge clk or negedge rst)
        if (!rst) ckdiv <= 24'd0; else ckdiv <= ckdiv + 24'd1;
    wire heartbeat = ckdiv[23];

    logic clk6m, clk1m;
    PLL_6M PLL6m (.clkout(clk6m), .clkoutd(clk1m), .clkin(clk));

    logic        clk50m, ready;
    logic        rx_head_av;  logic [31:0] rx_head;
    logic        rx_data_av;  logic [7:0]  rx_data;
    logic        rx_head_rdy;
    logic        rx_reject;
    logic [7:0]  hfifo_lvl;
    logic [12:0] dfifo_lvl;

    // TX unused in this test (RX-only stress) - tie off request-side inputs.
    logic [31:0] tx_ip=0;   logic [15:0] tx_src_port=0, tx_dst_port=0;
    logic [7:0]  tx_data=0; logic        tx_data_av=0, tx_req=0;
    logic        tx_req_rdy, tx_data_rdy;

    udp #(
        .ip_adr ({8'd192, 8'd168, 8'd15, 8'd14}),
        .mac_adr({8'h06, 8'h00, 8'hAA, 8'hBB, 8'h0C, 8'hDD}),
        .arp_refresh_interval(50000000*15),
        .arp_max_life_time   (50000000*30)
    ) udp_inst (
        .clk1m(clk1m), .rst(rst),
        .clk50m(clk50m), .ready(ready),
        .netrmii(netrmii), .phyrst(phyrst),
        .rx_head_rdy_i(rx_head_rdy), .rx_head_av_o(rx_head_av), .rx_head_o(rx_head),
        .rx_data_rdy_i(1'b1),        .rx_data_av_o(rx_data_av), .rx_data_o(rx_data),
        .tx_ip_i(tx_ip), .tx_src_port_i(tx_src_port), .tx_dst_port_i(tx_dst_port),
        .tx_req_i(tx_req), .tx_data_i(tx_data), .tx_data_av_i(tx_data_av),
        .tx_req_rdy_o(tx_req_rdy), .tx_data_rdy_o(tx_data_rdy),
        .rx_reject_o(rx_reject),
        .rx_head_fifo_level_o(hfifo_lvl), .rx_data_fifo_level_o(dfifo_lvl)
    );

    // drain the head FIFO immediately - we don't need header fields, just the
    // once-per-frame pulse rx_head_av gives us to know "a new UDP frame just landed".
    // Same 4-word pop cadence Sipeed's own examples use so the FIFO doesn't back up.
    logic [2:0] hstate;
    always_ff @(posedge clk50m or negedge ready) begin
        if (!ready) begin hstate <= 3'd0; rx_head_rdy <= 1'b0; end
        else begin
            rx_head_rdy <= 1'b0;
            case (hstate)
                0: if (rx_head_av) begin rx_head_rdy <= 1'b1; hstate <= 1; end
                1: begin rx_head_rdy <= 1'b1; hstate <= 2; end
                2: begin rx_head_rdy <= 1'b1; hstate <= 3; end
                3: begin rx_head_rdy <= 1'b1; hstate <= 4; end
                4: if (!rx_head_av) hstate <= 0;
                default: hstate <= 0;
            endcase
        end
    end

    wire core_rst = ~ready;

    // ---- RX byte stream (raw, no parser) ----
    logic [7:0] sdat;  logic sv, psv;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) begin sv <= 0; psv <= 0; sdat <= 0; end
        else begin sv <= rx_data_av; sdat <= rx_data; psv <= sv; end
    wire p_valid = sv, p_sop = sv & ~psv;

    // ---- SEQUENCE DECODE: first 4 bytes of every UDP payload are the seq number ----
    // p_sop marks the first payload byte of a new frame (rx_data_av just rose). udp.sv
    // has already stripped the Ethernet/IP/UDP headers before rx_data_av_o goes high,
    // so p_sop's byte IS the payload's first byte - no header parsing needed here.
    //
    // byte_idx counts 0,1,2,3 across the 4 seq bytes; seq_acc accumulates them
    // little-endian (byte 0 = bits[7:0], byte 3 = bits[31:24]). On the cycle AFTER the
    // 4th byte is folded in (byte_idx wraps back to 0), seq_acc holds the complete
    // value and seq_ready pulses so the comparison logic runs exactly once per packet.
    logic [2:0]  byte_idx;   // 3 bits: must count PAST 3 and STAY there (not wrap) for
                             // the rest of a 1280-byte payload, or the case below would
                             // restart decoding a bogus "seq number" every 4 bytes.
    logic [31:0] seq_acc;
    logic        seq_ready;
    wire  [2:0]  eff_idx = p_sop ? 3'd0 : byte_idx;   // p_sop always restarts the count
    always_ff @(posedge clk50m or posedge core_rst) begin
        if (core_rst) begin
            byte_idx <= 3'd0; seq_acc <= 32'd0; seq_ready <= 1'b0;
        end else begin
            seq_ready <= 1'b0;
            if (p_valid) begin
                case (eff_idx)
                    3'd0: seq_acc[7:0]   <= sdat;
                    3'd1: seq_acc[15:8]  <= sdat;
                    3'd2: seq_acc[23:16] <= sdat;
                    3'd3: begin seq_acc[31:24] <= sdat; seq_ready <= 1'b1; end
                    default: ;   // bytes 4..1279 of the payload: ignored, don't re-decode
                endcase
                if (eff_idx != 3'd4) byte_idx <= eff_idx + 3'd1;   // saturate at 4, don't wrap
            end
        end
    end

    logic [31:0] next_expected;
    logic [31:0] rx_cnt, gap_cnt, last_seq;
    logic        first_packet;
    // is_straggler: true when this packet's seq is a duplicate/reordered old value
    // (seq_acc < next_expected). 2026-07-31: confirmed in sim that a genuine UDP
    // duplicate (a normal, legal network event - UDP guarantees neither ordering nor
    // uniqueness) reproduces the exact GAP=0/RM>0 anomaly seen on real HW, because the
    // straggler's stale seq_acc was still being written into ring_mem below, silently
    // corrupting a slot a later legitimate packet expects to read back cleanly -
    // without ever touching gap_cnt. Gated the ring write on this signal to fix it.
    wire is_straggler = !first_packet && (seq_acc < next_expected);
    // seq_ready pulses the cycle AFTER seq_acc[31:24] is written (non-blocking), so
    // seq_acc is already the complete, settled value here.
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) begin
            next_expected <= 32'd0; rx_cnt <= 32'd0; gap_cnt <= 32'd0;
            last_seq <= 32'd0; first_packet <= 1'b1;
        end else if (seq_ready) begin
            rx_cnt   <= rx_cnt + 32'd1;
            last_seq <= seq_acc;
            if (first_packet) begin
                first_packet  <= 1'b0;
                next_expected <= seq_acc + 32'd1;
            end else if (seq_acc >= next_expected) begin
                gap_cnt       <= gap_cnt + (seq_acc - next_expected);
                next_expected <= seq_acc + 32'd1;
            end
            // seq_acc < next_expected (an out-of-order/duplicate straggler): don't
            // touch next_expected, just count it as received. (Ring write is
            // separately gated off via is_straggler, below.)
        end

    // ---- MINIMAL RING BUFFER FILL TEST (2026-07-20) ----
    // A separate, from-scratch check: can we fill a 32-slot ring with the incoming
    // sequence numbers WITHOUT LOSING/CORRUPTING an entry, at real network burst
    // rates? Each received packet writes seq_acc into mem[seq_acc mod NLINES] - no
    // "reader" is simulated (nothing here plays the video raster's role); instead,
    // since we know in advance exactly what value SHOULD already be in a slot before
    // we overwrite it (the sequence number NLINES writes ago, seq_acc - NLINES), we
    // check that BEFORE every write and count mismatches. A mismatch means the ring
    // itself corrupted or skipped a prior write - independent of any lap-guard/reader
    // logic, since there is none here.
    localparam integer RNLINES  = 32;
    localparam integer RSLOT_W  = 5;   // clog2(32)

    reg [31:0] ring_mem [0:RNLINES-1];
    wire [RSLOT_W-1:0] ring_slot = seq_acc[RSLOT_W-1:0];   // seq_acc mod 32

    // Split into two pipeline stages to shorten the critical path: stage 1 (on
    // seq_ready) latches the slot/expected-value/BRAM read and issues the write;
    // stage 2 (one clk50m cycle later) compares the now-settled read data against
    // the latched expected value. Combining the BRAM read, subtraction, and compare
    // in a single cycle was too tight at real burst rates (2026-07-20: this caused
    // RX to never advance at all under load - a timing failure, not a ring-fill bug).
    logic [31:0] ring_writes, ring_mismatches;
    logic        ring_primed;   // true once we've written >= RNLINES entries (so the
                                 // "expected previous value" check is meaningful - the
                                 // first lap around the ring has nothing real to compare against)
    logic        chk_valid;
    logic [31:0] chk_expected;
    logic [31:0] ring_rd;
    always_ff @(posedge clk50m or posedge core_rst) begin
        if (core_rst) begin
            ring_writes <= 32'd0; ring_mismatches <= 32'd0; ring_primed <= 1'b0;
            chk_valid <= 1'b0;
        end else begin
            // stage 2: compare using values latched last cycle
            chk_valid <= 1'b0;
            if (chk_valid && ring_rd !== chk_expected)
                ring_mismatches <= ring_mismatches + 32'd1;

            // stage 1: on a new packet, read+write the slot, latch for next-cycle compare.
            // Stragglers (is_straggler) are excluded entirely - a duplicate/reordered
            // packet must never overwrite ring_mem with its stale seq value.
            if (seq_ready && !is_straggler) begin
                ring_rd       <= ring_mem[ring_slot];
                chk_expected  <= seq_acc - RNLINES[31:0];
                chk_valid     <= ring_primed;
                ring_mem[ring_slot] <= seq_acc;
                ring_writes   <= ring_writes + 32'd1;
                if (!ring_primed && ring_writes + 32'd1 >= RNLINES[31:0])
                    ring_primed <= 1'b1;
            end
        end
    end

    // ---- UART debug: RX= GAP= LAST= REJ= HD= (matches gwline's 115200 8N1 framing) ----
    reg [31:0] q_rx, q_gap, q_last; reg [15:0] q_rej, q_hd;
    logic [15:0] rej_cnt;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) rej_cnt <= 16'd0;
        else if (rx_reject && rej_cnt != 16'hFFFF) rej_cnt <= rej_cnt + 16'd1;

    // HD = cumulative count of rx_head_av RISING edges (independent of the sequence
    // decode below) - proves whether udp.sv itself sees a new frame boundary per
    // packet, isolating "the stack never re-arms" from "our own byte_idx/p_sop logic
    // never resyncs".
    logic rx_head_av_q;
    logic [15:0] hd_cnt;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) begin rx_head_av_q <= 1'b0; hd_cnt <= 16'd0; end
        else begin
            rx_head_av_q <= rx_head_av;
            if (rx_head_av && !rx_head_av_q && hd_cnt != 16'hFFFF) hd_cnt <= hd_cnt + 16'd1;
        end

    reg [2:0] q_hstate; reg q_rxhav;
    reg [31:0] q_rw, q_rm;
    reg [7:0] q_hfl; reg [12:0] q_dfl;
    reg [7:0] hfl_max; reg [12:0] dfl_max;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) begin hfl_max <= 8'd0; dfl_max <= 13'd0; end
        else begin
            if (hfifo_lvl > hfl_max) hfl_max <= hfifo_lvl;
            if (dfifo_lvl > dfl_max) dfl_max <= dfifo_lvl;
        end
    always @(posedge clk50m) begin
        q_rx<=rx_cnt; q_gap<=gap_cnt; q_last<=last_seq; q_rej<=rej_cnt; q_hd<=hd_cnt;
        q_hstate<=hstate; q_rxhav<=rx_head_av;
        q_rw<=ring_writes; q_rm<=ring_mismatches;
        q_hfl<=hfl_max; q_dfl<=dfl_max;
    end

    wire [7:0] tx_din; wire tx_wr, tx_busy;
    uart_tx_V2 #(.clk_freq(27_000_000), .uart_freq(115200)) u_dbgtx (
        .clk(clk), .din(tx_din), .wr_en(tx_wr), .tx_busy(tx_busy), .tx_p(uart_txp));
    function [7:0] hxd; input [3:0] n; hxd = (n<4'd10)?(8'h30+n):(8'h41+n-4'd10); endfunction
    localparam [7:0] DBGLEN = 8'd126;
    reg [7:0] di=0, dtx=0; reg dwr=0; reg [2:0] dst=0; reg [23:0] dhold=0; reg [7:0] dlb;
    always @(*) begin
        case (di)
            0:dlb="R";1:dlb="X";2:dlb="=";
            3:dlb=hxd(q_rx[31:28]);4:dlb=hxd(q_rx[27:24]);5:dlb=hxd(q_rx[23:20]);6:dlb=hxd(q_rx[19:16]);
            7:dlb=hxd(q_rx[15:12]);8:dlb=hxd(q_rx[11:8]);9:dlb=hxd(q_rx[7:4]);10:dlb=hxd(q_rx[3:0]);11:dlb=" ";
            12:dlb="G";13:dlb="A";14:dlb="P";15:dlb="=";
            16:dlb=hxd(q_gap[31:28]);17:dlb=hxd(q_gap[27:24]);18:dlb=hxd(q_gap[23:20]);19:dlb=hxd(q_gap[19:16]);
            20:dlb=hxd(q_gap[15:12]);21:dlb=hxd(q_gap[11:8]);22:dlb=hxd(q_gap[7:4]);23:dlb=hxd(q_gap[3:0]);24:dlb=" ";
            25:dlb="L";26:dlb="A";27:dlb="S";28:dlb="T";29:dlb="=";
            30:dlb=hxd(q_last[31:28]);31:dlb=hxd(q_last[27:24]);32:dlb=hxd(q_last[23:20]);33:dlb=hxd(q_last[19:16]);
            34:dlb=hxd(q_last[15:12]);35:dlb=hxd(q_last[11:8]);36:dlb=hxd(q_last[7:4]);37:dlb=hxd(q_last[3:0]);38:dlb=" ";
            39:dlb="R";40:dlb="E";41:dlb="J";42:dlb="=";
            43:dlb=hxd(q_rej[15:12]);44:dlb=hxd(q_rej[11:8]);45:dlb=hxd(q_rej[7:4]);46:dlb=hxd(q_rej[3:0]);47:dlb=" ";
            48:dlb="H";49:dlb="D";50:dlb="=";
            51:dlb=hxd(q_hd[15:12]);52:dlb=hxd(q_hd[11:8]);53:dlb=hxd(q_hd[7:4]);54:dlb=hxd(q_hd[3:0]);55:dlb=" ";
            56:dlb="H";57:dlb="S";58:dlb="=";59:dlb=hxd({1'b0,q_hstate});60:dlb=" ";
            61:dlb="H";62:dlb="V";63:dlb="=";64:dlb=hxd({3'b0,q_rxhav});
            65:dlb=" ";66:dlb="R";67:dlb="W";68:dlb="=";
            69:dlb=hxd(q_rw[31:28]);70:dlb=hxd(q_rw[27:24]);71:dlb=hxd(q_rw[23:20]);72:dlb=hxd(q_rw[19:16]);
            73:dlb=hxd(q_rw[15:12]);74:dlb=hxd(q_rw[11:8]);75:dlb=hxd(q_rw[7:4]);76:dlb=hxd(q_rw[3:0]);77:dlb=" ";
            78:dlb="R";79:dlb="M";80:dlb="=";
            81:dlb=hxd(q_rm[31:28]);82:dlb=hxd(q_rm[27:24]);83:dlb=hxd(q_rm[23:20]);84:dlb=hxd(q_rm[19:16]);
            85:dlb=hxd(q_rm[15:12]);86:dlb=hxd(q_rm[11:8]);87:dlb=hxd(q_rm[7:4]);88:dlb=hxd(q_rm[3:0]);
            89:dlb=" ";90:dlb="H";91:dlb="L";92:dlb="=";
            93:dlb=hxd(q_hfl[7:4]);94:dlb=hxd(q_hfl[3:0]);95:dlb=" ";
            96:dlb="D";97:dlb="L";98:dlb="=";
            99:dlb=hxd({3'b0,q_dfl[12]});100:dlb=hxd(q_dfl[11:8]);
            101:dlb=hxd(q_dfl[7:4]);102:dlb=hxd(q_dfl[3:0]);
            124:dlb=8'h0D;125:dlb=8'h0A;default:dlb=" ";
        endcase
    end
    always @(posedge clk) begin
        dwr<=1'b0;
        case (dst)
            3'd0: begin di<=0; dst<=3'd1; end
            3'd1: begin dtx<=dlb; dwr<=1'b1; dst<=3'd2; end
            3'd2: if (tx_busy) dst<=3'd3;
            3'd3: if (!tx_busy) begin
                if (di==DBGLEN-1) begin dst<=3'd4; dhold<=24'd2_700_000; end
                else begin di<=di+1'b1; dst<=3'd1; end
            end
            3'd4: if (dhold==0) dst<=3'd0; else dhold<=dhold-1'b1;
        endcase
    end
    assign tx_din=dtx; assign tx_wr=dwr;

    // diagnostics LEDs (active-low; lit = true): [5]=heartbeat [4]=ready [3]=clk50m
    // toggling [2]=rx_seen [1]=gap ever seen [0]=reject ever seen
    logic [22:0] ck50;  logic rx_seen;
    always_ff @(posedge clk50m or negedge rst)
        if (!rst) begin ck50 <= 0; rx_seen <= 0; end
        else begin ck50 <= ck50 + 23'd1; if (rx_data_av) rx_seen <= 1'b1; end
    wire clk50_hb = ck50[22];
    assign led = ~{heartbeat, ready, clk50_hb, rx_seen, (gap_cnt!=0), (rej_cnt!=0)};
endmodule
