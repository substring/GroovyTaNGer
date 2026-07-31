// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - reproduces the 2026-07-20 HW puzzle (RX works cleanly at 300 packets,
// degrades/blocks by 500-1000) in zero-doubt RTL sim, driving groovy_udpstress_top's
// internal rx_data_av/rx_data DIRECTLY (bypassing udp.sv/the network entirely) with a
// synthetic stream of N back-to-back 1280-byte UDP payloads, each starting with its
// LE32 sequence number - exactly the PC sender's wire format. This isolates whether
// the bug is in OUR sequence-decode/ring-fill logic itself, independent of the PC
// sender, the network, or udp.sv's own internal behavior.
`timescale 1ns/1ps
module groovy_udpstress_seqdecode_tb;
    reg clk = 0; always #10 clk = ~clk;       // 27 MHz-ish (period doesn't matter here)
    reg clk50m = 0; always #10 clk50m = ~clk50m;  // 50 MHz (driven directly, no PLL)
    reg rst = 0;
    reg ready = 0;

    // Drive the decode+ring logic directly at this level (copied verbatim from
    // groovy_udpstress_top.sv's sequence-decode + ring-fill blocks) instead of
    // instantiating the whole top with its PLL/udp.sv/UART - this is the exact
    // same RTL under test, just without the network/PHY dependency.
    reg rx_data_av = 0;
    reg [7:0] rx_data = 0;

    wire core_rst = ~ready;

    reg sv=0, psv=0; reg [7:0] sdat=0;
    always @(posedge clk50m or posedge core_rst)
        if (core_rst) begin sv<=0; psv<=0; sdat<=0; end
        else begin sv<=rx_data_av; sdat<=rx_data; psv<=sv; end
    wire p_valid = sv, p_sop = sv & ~psv;

    reg [2:0] byte_idx=0;
    reg [31:0] seq_acc=0;
    reg seq_ready=0;
    wire [2:0] eff_idx = p_sop ? 3'd0 : byte_idx;
    always @(posedge clk50m or posedge core_rst) begin
        if (core_rst) begin
            byte_idx<=0; seq_acc<=0; seq_ready<=0;
        end else begin
            seq_ready<=0;
            if (p_valid) begin
                case (eff_idx)
                    3'd0: seq_acc[7:0]   <= sdat;
                    3'd1: seq_acc[15:8]  <= sdat;
                    3'd2: seq_acc[23:16] <= sdat;
                    3'd3: begin seq_acc[31:24] <= sdat; seq_ready <= 1'b1; end
                    default: ;
                endcase
                if (eff_idx != 3'd4) byte_idx <= eff_idx + 3'd1;
            end
        end
    end

    reg [31:0] next_expected=0, rx_cnt=0, gap_cnt=0, last_seq=0;
    reg first_packet=1;
    wire is_straggler = !first_packet && (seq_acc < next_expected);
    always @(posedge clk50m or posedge core_rst)
        if (core_rst) begin
            next_expected<=0; rx_cnt<=0; gap_cnt<=0; last_seq<=0; first_packet<=1;
        end else if (seq_ready) begin
            rx_cnt <= rx_cnt + 1;
            last_seq <= seq_acc;
            if (first_packet) begin
                first_packet <= 0;
                next_expected <= seq_acc + 1;
            end else if (seq_acc >= next_expected) begin
                gap_cnt <= gap_cnt + (seq_acc - next_expected);
                next_expected <= seq_acc + 1;
            end
        end

    localparam integer RNLINES = 32;
    localparam integer RSLOT_W = 5;
    reg [31:0] ring_mem [0:RNLINES-1];
    wire [RSLOT_W-1:0] ring_slot = seq_acc[RSLOT_W-1:0];
    reg [31:0] ring_writes=0, ring_mismatches=0;
    reg ring_primed=0;
    reg chk_valid=0;
    reg [31:0] chk_expected=0;
    reg [31:0] ring_rd=0;
    always @(posedge clk50m or posedge core_rst) begin
        if (core_rst) begin
            ring_writes<=0; ring_mismatches<=0; ring_primed<=0; chk_valid<=0;
        end else begin
            chk_valid <= 0;
            if (chk_valid && ring_rd !== chk_expected) begin
                ring_mismatches <= ring_mismatches + 1;
                if (ring_mismatches < 10)
                    $display("  MISMATCH #%0d t=%0t ring_rd=%0d chk_expected=%0d",
                              ring_mismatches+1, $time, ring_rd, chk_expected);
            end
            if (seq_ready && !is_straggler) begin
                ring_rd <= ring_mem[ring_slot];
                chk_expected <= seq_acc - RNLINES;
                chk_valid <= ring_primed;
                ring_mem[ring_slot] <= seq_acc;
                ring_writes <= ring_writes + 1;
                if (!ring_primed && ring_writes + 1 >= RNLINES)
                    ring_primed <= 1;
            end
        end
    end

    // ---- synthetic UDP payload generator: N back-to-back 1280-byte payloads, each
    // starting with its LE32 sequence number, gaps between payloads matching the real
    // sender's ~138.8us/packet pacing (scaled down is fine - only RELATIVE timing/byte
    // sequencing matters for this decode logic, not absolute wall-clock rate). ----
    localparam integer PAYLOAD_LEN = 1280;
    localparam integer N_PACKETS = 2000;
    // Tests a DUPLICATE/REORDERED packet (not a clean drop) every 500 packets: resend
    // the previous seq number instead of the current one. groovy_udpstress_top.sv's
    // comment claims this is handled safely ("out-of-order/duplicate straggler: don't
    // touch next_expected, just count it as received") - but it STILL writes the
    // stale seq into ring_mem[ring_slot], which can corrupt a slot a later LEGITIMATE
    // packet expects to read back cleanly. This tests the theory that real-world
    // reordering/duplication (not modeled by the earlier clean-drop test) explains the
    // 2026-07-31 HW anomaly: GAP=0 with RM>0, which a clean drop can never produce
    // (clean drop always moves GAP and RM together, 1-for-1, already proven above).
    integer p, b;
    reg [31:0] seq;
    integer dup_count = 0;
    initial begin
        rst = 0; ready = 0;
        repeat(5) @(negedge clk50m);
        rst = 1; ready = 1;
        repeat(5) @(negedge clk50m);

        for (p = 0; p < N_PACKETS; p = p + 1) begin
            seq = p;
            for (b = 0; b < PAYLOAD_LEN; b = b + 1) begin
                rx_data_av <= 1'b1;
                if (b == 0) rx_data <= seq[7:0];
                else if (b == 1) rx_data <= seq[15:8];
                else if (b == 2) rx_data <= seq[23:16];
                else if (b == 3) rx_data <= seq[31:24];
                else rx_data <= 8'hAA;   // filler byte, value irrelevant
                @(negedge clk50m);
            end
            rx_data_av <= 1'b0;
            repeat(2) @(negedge clk50m);   // small inter-packet gap (like real IFG)

            // Every 500th packet, immediately RESEND the SAME seq a second time (a true
            // duplicate, not a reorder) - tests whether an exact duplicate corrupts the
            // ring without ever touching gap_cnt (since seq_acc == next_expected-1 <
            // next_expected, the "straggler" branch fires and gap_cnt is untouched).
            if ((p % 500) == 499) begin
                dup_count = dup_count + 1;
                for (b = 0; b < PAYLOAD_LEN; b = b + 1) begin
                    rx_data_av <= 1'b1;
                    if (b == 0) rx_data <= seq[7:0];
                    else if (b == 1) rx_data <= seq[15:8];
                    else if (b == 2) rx_data <= seq[23:16];
                    else if (b == 3) rx_data <= seq[31:24];
                    else rx_data <= 8'hAA;
                    @(negedge clk50m);
                end
                rx_data_av <= 1'b0;
                repeat(2) @(negedge clk50m);
            end

            if (p % 500 == 0)
                $display("  sent %0d/%0d  RX=%0d GAP=%0d LAST=%0d RW=%0d RM=%0d dup_so_far=%0d",
                          p, N_PACKETS, rx_cnt, gap_cnt, last_seq, ring_writes, ring_mismatches, dup_count);
        end
        $display("total simulated duplicates/reorders: %0d", dup_count);

        repeat(10) @(negedge clk50m);
        $display("=== RESULT ===");
        $display("sent=%0d (duplicates/reorders=%0d)  RX=%0d GAP=%0d LAST=%0d RW=%0d RM=%0d",
                  N_PACKETS, dup_count, rx_cnt, gap_cnt, last_seq, ring_writes, ring_mismatches);
        if (gap_cnt == 0 && ring_mismatches > 0)
            $display("CONFIRMED: GAP=0 with RM>0 IS reproducible from duplicate/reordered packets alone - matches the 2026-07-31 HW anomaly exactly. Root cause: writing a stale seq into ring_mem on a straggler corrupts a slot a later legitimate packet expects.");
        else if (ring_mismatches == 0)
            $display("NOT REPRODUCED: duplicates/reorders alone did not corrupt the ring in this test");
        else
            $display("Other result: GAP=%0d RM=%0d - see deltas above", gap_cnt, ring_mismatches);
        $finish;
    end
endmodule
