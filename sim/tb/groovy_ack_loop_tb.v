// SPDX-License-Identifier: GPL-2.0-or-later
// Rung 1 end-to-end sim: parser -> ack_policy -> ack_sender.
// Feeds control packets as a byte stream (as Ethernet/UDP would, once built) and
// checks the 13-byte ACK that comes back, per docs/protocol_verified.md:
//   INIT  -> ACK with frameEcho=0, vCountEcho=0, fpga frame/vCount/status
//   BLIT  -> ACK echoing the blit's frame and vSync
`timescale 1ns/1ps
module groovy_ack_loop_tb;
    reg clk = 0;
    always #5 clk = ~clk;

    reg        rst, in_valid, in_sop, in_eop;
    reg  [7:0] in_data;
    // simulated FPGA raster status
    reg [31:0] fpga_frame  = 32'hAABBCCDD;
    reg [15:0] fpga_vcount = 16'h1234;
    reg [7:0]  status_bits = 8'h5A;
    integer    errors = 0;

    // parser <-> policy
    wire        init_valid, get_status_valid, blit_valid;
    wire [31:0] blit_frame;
    wire [15:0] blit_vsync;
    // policy <-> sender
    wire        ack_start, ack_busy;
    wire [31:0] ack_frame_echo, ack_fpga_frame;
    wire [15:0] ack_vsync_echo, ack_fpga_vcount;
    wire [7:0]  ack_status;
    // sender output
    wire        out_valid, out_last;
    wire [7:0]  out_data;

    groovy_packet_parser u_parser (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_data(in_data), .in_sop(in_sop), .in_eop(in_eop),
        .cmd_valid(), .cmd(), .bad_packet(),
        .close_valid(), .init_valid(init_valid), .switchres_valid(),
        .audio_valid(), .get_status_valid(get_status_valid), .blit_valid(blit_valid),
        .get_version_valid(),
        .init_lz4(), .init_sound_rate(), .init_sound_chan(), .init_rgb_mode(),
        .sr_pclk(), .sr_h_active(), .sr_h_begin(), .sr_h_end(), .sr_h_total(),
        .sr_v_active(), .sr_v_begin(), .sr_v_end(), .sr_v_total(), .sr_interlace(),
        .audio_size(),
        .blit_frame(blit_frame), .blit_field(), .blit_vsync(blit_vsync),
        .blit_lz4(), .blit_csize(), .blit_flag());

    groovy_ack_policy u_policy (
        .clk(clk), .rst(rst),
        .init_valid(init_valid), .get_status_valid(get_status_valid),
        .blit_valid(blit_valid), .blit_frame(blit_frame), .blit_vsync(blit_vsync),
        .fpga_frame(fpga_frame), .fpga_vcount(fpga_vcount), .status_bits(status_bits),
        .ack_busy(ack_busy),
        .ack_start(ack_start),
        .ack_frame_echo(ack_frame_echo), .ack_vsync_echo(ack_vsync_echo),
        .ack_fpga_frame(ack_fpga_frame), .ack_fpga_vcount(ack_fpga_vcount),
        .ack_status(ack_status));

    groovy_ack_sender u_ack (
        .clk(clk), .rst(rst), .start(ack_start),
        .frame_echo(ack_frame_echo), .vsync_echo(ack_vsync_echo),
        .fpga_vga_frame(ack_fpga_frame), .fpga_vga_vcount(ack_fpga_vcount),
        .status_bits(ack_status),
        .out_valid(out_valid), .out_data(out_data), .out_last(out_last),
        .out_ready(1'b1), .busy(ack_busy));

    // capture every ACK byte emitted
    reg [7:0] cap [0:63];
    integer   capn = 0;
    always @(posedge clk)
        if (!rst && out_valid) begin cap[capn] = out_data; capn = capn + 1; end

    task send_byte; input [7:0] d; input s; input e;
    begin
        @(negedge clk); in_valid=1; in_data=d; in_sop=s; in_eop=e;
        @(negedge clk); in_valid=0; in_sop=0; in_eop=0;
    end endtask

    // check a 13-byte ACK starting at cap[base]
    task check_ack; input integer base;
        input [31:0] exp_fe; input [15:0] exp_ve;
        reg [31:0] fe, fr; reg [15:0] ve, vc; reg [7:0] st;
    begin
        fe = {cap[base+3],cap[base+2],cap[base+1],cap[base+0]};
        ve = {cap[base+5],cap[base+4]};
        fr = {cap[base+9],cap[base+8],cap[base+7],cap[base+6]};
        vc = {cap[base+11],cap[base+10]};
        st =  cap[base+12];
        if (fe!==exp_fe||ve!==exp_ve||fr!==fpga_frame||vc!==fpga_vcount||st!==status_bits) begin
            $display("FAIL: ACK@%0d fe=%h(exp %h) ve=%h(exp %h) fr=%h vc=%h st=%h",
                     base, fe, exp_fe, ve, exp_ve, fr, vc, st);
            errors = errors + 1;
        end
    end endtask

    initial begin
        rst=1; in_valid=0; in_sop=0; in_eop=0; in_data=0;
        @(negedge clk); @(negedge clk); rst=0;

        // INIT (5 bytes) -> ACK echoes 0/0
        send_byte(8'd2,1,0); send_byte(8'd0,0,0); send_byte(8'd3,0,0);
        send_byte(8'd2,0,0); send_byte(8'd0,0,1);
        wait (capn >= 13); @(negedge clk);
        check_ack(0, 32'd0, 16'd0);

        // BLIT raw 8 -> ACK echoes frame=0x04030201, vsync=0x0706
        send_byte(8'd7,1,0);
        send_byte(8'h01,0,0); send_byte(8'h02,0,0); send_byte(8'h03,0,0); send_byte(8'h04,0,0);
        send_byte(8'h00,0,0);                       // field
        send_byte(8'h06,0,0); send_byte(8'h07,0,1); // vsync
        wait (capn >= 26); @(negedge clk);
        check_ack(13, 32'h04030201, 16'h0706);

        if (errors == 0) $display("PASS: groovy_ack_loop_tb (%0d ACK bytes)", capn);
        else begin $display("FAIL: groovy_ack_loop_tb (%0d errors)", errors); $fatal(1); end
        $finish;
    end
endmodule
