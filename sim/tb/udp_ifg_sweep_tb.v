// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - minimum inter-frame gap of udp.sv's receive path.
//
// Clocks 12 identical, valid 1326-byte Ethernet frames (a real captured gwline pixel
// datagram + FCS) into a real udp.sv over RMII, separated by +IFG=<clk50m cycles>, and
// counts how many come out. Run it across a range of gaps:
//   before the 2026-10-11 CRC_check rework: 12/12 at 1300 cycles, 0/12 at 1200 - the
//     stack needed a gap as long as the previous frame's drain (1 cycle per byte);
//   after: 12/12 down to 24 cycles (below the 48-cycle Ethernet IFG).
// It checks the COUNT of frames and payload bytes only; payload content through udp.sv
// is checked pixel-exact by gwline_top_e2e_tb.sv.
`timescale 1ns/1ps
`include "rmii.svh"

module udp_ifg_sweep_tb;
    reg clk1m = 0; always #500 clk1m = ~clk1m;      // 1 MHz
    reg clk50m = 0; always #10 clk50m = ~clk50m;    // 50 MHz
    reg rst = 0;

    reg  [1:0] rxd_drv = 0;
    reg        crs_drv = 0;
    wire       mdio_w;
    rmii netrmii(.clk50m(clk50m), .rx_crs(crs_drv), .mdc(), .txen(), .mdio(mdio_w),
                 .txd(), .rxd(rxd_drv));
    wire phyrst;
    reg  rx_head_rdy = 1;
    wire rx_head_av;
    wire [31:0] rx_head;
    reg  rx_data_rdy = 1;
    wire rx_data_av;
    wire [7:0] rx_data;
    reg [31:0] tx_ip=0; reg [15:0] tx_src_port=0, tx_dst_port=0;
    reg [7:0] tx_data=0; reg tx_data_av=0, tx_req=0;
    wire tx_req_rdy, tx_data_rdy;
    wire rx_reject;
    wire [7:0] hfl; wire [12:0] dfl;

    logic ready;
    udp #(
        .ip_adr ({8'd192, 8'd168, 8'd15, 8'd14}),
        .mac_adr({8'h06, 8'h00, 8'hAA, 8'hBB, 8'h0C, 8'hDD}),
        .arp_refresh_interval(50000000*15),
        .arp_max_life_time   (50000000*30)
    ) dut (
        .clk1m(clk1m), .rst(rst),
        .clk50m(clk50m), .ready(ready),
        .netrmii(netrmii), .phyrst(phyrst),
        .rx_head_rdy_i(rx_head_rdy), .rx_head_av_o(rx_head_av), .rx_head_o(rx_head),
        .rx_data_rdy_i(rx_data_rdy), .rx_data_av_o(rx_data_av), .rx_data_o(rx_data),
        .tx_ip_i(tx_ip), .tx_src_port_i(tx_src_port), .tx_dst_port_i(tx_dst_port),
        .tx_req_i(tx_req), .tx_data_i(tx_data), .tx_data_av_i(tx_data_av),
        .tx_req_rdy_o(tx_req_rdy), .tx_data_rdy_o(tx_data_rdy),
        .rx_reject_o(rx_reject),
        .rx_head_fifo_level_o(hfl), .rx_data_fifo_level_o(dfl)
    );

    // Drive RMII: rx_crs high for the duration of the frame, rxd carries 2 bits/cycle
    // LSB-first per byte (matches rx_data_s <= {rxd, rx_data_s[7:2]} shifting behavior).
    // (rxd_drv/crs_drv now declared above, wired directly into the netrmii instance ports.)

    // NFRAME = 1322 captured bytes (tcpdump strips the FCS) + 4-byte Ethernet FCS/CRC32
    // trailer, WITHOUT which CRC_check's stp-triggered crc==32'hC704DD7B check never
    // passes and rx_data_rdy/fin never pulse - this was the actual bug in the FIRST
    // version of this testbench (looked like a udp.sv defect, was a missing-FCS
    // testbench artifact). FCS computed independently via Python zlib.crc32, sent
    // little-endian (LSB-first byte order) as real Ethernet transmits it: c3 4a 5e f8.
    localparam integer NFRAME = 1326;
    reg [7:0] frame [0:NFRAME-1];
    initial begin
        frame[0]=8'h06;frame[1]=8'h00;frame[2]=8'haa;frame[3]=8'hbb;frame[4]=8'h0c;frame[5]=8'hdd;frame[6]=8'h3c;frame[7]=8'h7c;frame[8]=8'h3f;frame[9]=8'hc3;frame[10]=8'h2c;frame[11]=8'h22;frame[12]=8'h08;frame[13]=8'h00;frame[14]=8'h45;frame[15]=8'h00;frame[16]=8'h05;frame[17]=8'h1c;frame[18]=8'h00;frame[19]=8'hfa;frame[20]=8'h40;frame[21]=8'h00;frame[22]=8'h40;frame[23]=8'h11;frame[24]=8'h95;frame[25]=8'h69;frame[26]=8'hc0;frame[27]=8'ha8;frame[28]=8'h0f;frame[29]=8'h0f;frame[30]=8'hc0;frame[31]=8'ha8;frame[32]=8'h0f;frame[33]=8'h0e;frame[34]=8'he5;frame[35]=8'hae;frame[36]=8'h7d;frame[37]=8'h64;frame[38]=8'h05;frame[39]=8'h08;frame[40]=8'h0c;frame[41]=8'h59;frame[42]=8'he7;frame[43]=8'h03;
        // payload bytes 44..1321 are all zero-fill except the 4 seq bytes already placed above (idx 42-45 = seq LE);
        // fill the rest with the same zero padding the real sender used.
        for (integer i = 44; i < 1322; i = i + 1) frame[i] = 8'h00;
        frame[1322]=8'hc3; frame[1323]=8'h4a; frame[1324]=8'h5e; frame[1325]=8'hf8;   // FCS
    end

    // send one preamble+SFD+frame+IFG cycle over RMII, byte-by-byte, 2 bits/cycle
    task send_byte(input [7:0] b);
        integer k;
        begin
            for (k = 0; k < 4; k = k + 1) begin
                rxd_drv = b[1:0];
                b = b >> 2;
                @(posedge clk50m);
            end
        end
    endtask

    reg [7:0] prev_status = 8'hFF;
    always @(posedge clk50m) begin
        if (dut.ethernet_resolve_status !== prev_status) begin
            $display("  t=%0t  ethernet_resolve_status: %0d -> %0d  (byte_cnt=%0d checksum=%0h)",
                      $time, prev_status, dut.ethernet_resolve_status, dut.rx_data_byte_cnt, dut.checksum);
            prev_status <= dut.ethernet_resolve_status;
        end
    end
    reg [7:0] prev_rxstate = 8'hFF;
    always @(posedge clk50m) begin
        if (dut.rx_state !== prev_rxstate) begin
            $display("  t=%0t  rx_state: %0d -> %0d  (tick=%0d rx_data_s=%0h crs=%0d rxd=%0d fifo_in=%0d fifo_d=%0h)",
                      $time, prev_rxstate, dut.rx_state, dut.tick, dut.rx_data_s, dut.crs, dut.rxd, dut.fifo_in, dut.fifo_d);
            prev_rxstate <= dut.rx_state;
        end
    end
    integer fifoin_count = 0;
    integer sample_count = 0;
    always @(posedge clk50m) begin
        if (dut.fifo_in) fifoin_count <= fifoin_count + 1;
        if (dut.rx_state == 3 && sample_count < 20) begin
            $display("  t=%0t  [rx_state==3] tick=%0d crs=%0d fifo_in=%0d",
                      $time, dut.tick, dut.crs, dut.fifo_in);
            sample_count <= sample_count + 1;
        end
    end
    always @(posedge clk50m) begin
        if (dut.rx_data_rdy)
            $display("  t=%0t  rx_data_rdy PULSE  rx_data_fin=%0d fifoin_count_so_far=%0d",
                      $time, dut.rx_data_fin, fifoin_count);
    end
    integer rx_head_av_pulses = 0;
    always @(posedge clk50m) begin
        if (rx_head_av) begin
            rx_head_av_pulses <= rx_head_av_pulses + 1;
            $display("  t=%0t  rx_head_av PULSE #%0d  rx_head=%0h", $time, rx_head_av_pulses+1, rx_head);
        end
    end

    integer dbytes=0; always @(posedge clk50m) if (rx_data_av) dbytes<=dbytes+1;
    localparam integer N_FRAMES = 12;
    integer IFG_CYCLES = 1640; initial void'($value$plusargs("IFG=%d", IFG_CYCLES));

    integer i;
    initial begin
        rst = 0; crs_drv = 0; rxd_drv = 0;
        // udp.sv's phy_rdy depends on real MDIO negotiation with the RTL8201, which
        // this tb doesn't model - force it directly so we can test the RMII receive/
        // checksum path in isolation (real link-up already independently proven true
        // on HW). CRITICAL: force it LOW first so the always_ff@(... or negedge phy_rdy)
        // reset blocks see their normal reset state, THEN force a real 0->1 edge -
        // forcing straight to 1 with no prior edge never wakes an edge-sensitive block.
        force dut.phy_rdy = 1'b0;
        repeat(10) @(posedge clk50m);
        rst = 1;
        repeat(10) @(posedge clk50m);
        force dut.phy_rdy = 1'b1;   // real edge: 0 -> 1
        repeat(5) @(posedge clk50m);

        // Send N_FRAMES back-to-back frames, IDENTICAL bytes each time (the checksum
        // stays valid since we don't touch the seq bytes - this tests whether BURSTING
        // multiple frames with a realistic IFG breaks acceptance, independent of
        // whether the sequence content itself changes), separated by the real IFG
        // computed from gwline's actual pacing: 138.8us/packet - ~106.1us transmission
        // time = ~32.8us gap = 1640 clk50m cycles at 20ns/cycle.
        for (int f = 0; f < N_FRAMES; f = f + 1) begin
            $display("--- Sending frame %0d/%0d ---", f+1, N_FRAMES);
            crs_drv = 1'b1;
            for (i = 0; i < 7; i = i + 1) send_byte(8'h55);   // preamble
            send_byte(8'hD5);                                 // SFD
            for (i = 0; i < NFRAME; i = i + 1) send_byte(frame[i]);
            crs_drv = 1'b0;
            repeat(IFG_CYCLES) @(posedge clk50m);
        end

        repeat(3000) @(posedge clk50m);   // let the CRC_check readout pipeline drain
                                            // the full 1280B payload before checking result
        $display("SUMMARY ifg_cycles=%0d frames_ok=%0d/%0d payload_bytes=%0d/%0d", IFG_CYCLES, rx_head_av_pulses/4, N_FRAMES, dbytes, N_FRAMES*1280);
        $display("ethernet_resolve_status (final) = %0d", dut.ethernet_resolve_status);
        $display("rx_head_av_o = %0d  rx_head_fifo_head=%0d rx_head_fifo_tail=%0d",
                  rx_head_av, dut.rx_head_fifo_head, dut.rx_head_fifo_tail);
        $display("rx_data_fifo_head=%0d rx_data_fifo_tail=%0d", dut.rx_data_fifo_head, dut.rx_data_fifo_tail);
        $display("hfl=%0d dfl=%0d rx_reject=%0d", hfl, dfl, rx_reject);
        $display("total rx_head_av pulses observed: %0d (expected %0d = %0d frames x 4 header words)",
                  rx_head_av_pulses, N_FRAMES*4, N_FRAMES);
        if (rx_head_av_pulses == N_FRAMES*4)
            $display("PASS: ALL %0d frames accepted cleanly under realistic burst pacing", N_FRAMES);
        else
            $display("FAIL: only %0d/%0d expected header pulses fired - burst/back-to-back frames DO break udp.sv",
                      rx_head_av_pulses, N_FRAMES*4);
        $finish;
    end
endmodule
