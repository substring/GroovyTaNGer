// SPDX-License-Identifier: GPL-2.0-or-later
// Self-checking tb: CMD_GET_FEATURES (v2.0.0) end to end.
// Feeds a 1-byte cmd-9 packet through groovy_packet_parser; its
// get_features_valid starts groovy_features; checks the 12-byte descriptor.
`timescale 1ns/1ps
module groovy_features_tb;
    reg clk = 0;
    always #5 clk = ~clk;

    // capability set advertised in this test
    localparam [7:0] COMP = 8'h0B;   // RAW | LZ4 | QOI
    localparam [7:0] RGB  = 8'h05;   // RGB888 | RGB565

    reg        rst, in_valid, in_sop, in_eop;
    reg  [7:0] in_data;
    wire       get_features_valid;
    wire       out_valid, out_last, busy;
    wire [7:0] out_data;
    integer    errors = 0, k;

    groovy_packet_parser u_parser (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_data(in_data), .in_sop(in_sop), .in_eop(in_eop),
        .cmd_valid(), .cmd(), .bad_packet(),
        .close_valid(), .init_valid(), .switchres_valid(), .audio_valid(),
        .get_status_valid(), .blit_valid(), .get_version_valid(),
        .get_features_valid(get_features_valid),
        .init_lz4(), .init_sound_rate(), .init_sound_chan(), .init_rgb_mode(),
        .sr_pclk(), .sr_h_active(), .sr_h_begin(), .sr_h_end(), .sr_h_total(),
        .sr_v_active(), .sr_v_begin(), .sr_v_end(), .sr_v_total(), .sr_interlace(),
        .audio_size(),
        .blit_frame(), .blit_field(), .blit_vsync(),
        .blit_lz4(), .blit_csize(), .blit_flag());

    groovy_features #(
        .PROTO_MAJOR(8'd2), .PROTO_MINOR(8'd0), .PROTO_PATCH(8'd0),
        .COMPRESSION(COMP), .RGB_MODES(RGB)
    ) u_feat (
        .clk(clk), .rst(rst), .start(get_features_valid),
        .out_valid(out_valid), .out_data(out_data), .out_last(out_last),
        .out_ready(1'b1), .busy(busy));

    reg [7:0] cap [0:31];
    integer   capn = 0;
    reg       last_seen;
    always @(posedge clk)
        if (!rst && out_valid) begin
            cap[capn] = out_data;
            if (out_last) last_seen = 1'b1;
            capn = capn + 1;
        end

    task send_byte; input [7:0] d; input s; input e;
    begin
        @(negedge clk); in_valid=1; in_data=d; in_sop=s; in_eop=e;
        @(negedge clk); in_valid=0; in_sop=0; in_eop=0;
    end endtask

    reg [7:0] exp [0:11];
    initial begin
        rst=1; in_valid=0; in_sop=0; in_eop=0; in_data=0; last_seen=0;
        @(negedge clk); @(negedge clk); rst=0;

        send_byte(8'd9, 1, 1);                 // CMD_GET_FEATURES
        wait (capn >= 12); @(negedge clk);

        exp[0]=8'h47; exp[1]=8'h54; exp[2]=8'h46; exp[3]=8'h31;  // 'GTF1'
        exp[4]=8'd2;  exp[5]=8'd0;  exp[6]=8'd0;                  // 2.0.0
        exp[7]=COMP;  exp[8]=RGB;
        exp[9]=8'd0;  exp[10]=8'd0; exp[11]=8'd0;
        for (k=0;k<12;k=k+1)
            if (cap[k] !== exp[k]) begin
                $display("FAIL: byte %0d = %h expected %h", k, cap[k], exp[k]);
                errors=errors+1;
            end
        if (capn !== 12) begin
            $display("FAIL: got %0d bytes, expected 12", capn); errors=errors+1; end
        if (!last_seen) begin $display("FAIL: out_last never asserted"); errors=errors+1; end

        $display("  FEATURES descriptor emitted: magic=%c%c%c%c  proto v%0d.%0d.%0d  comp=0x%02h  rgb=0x%02h  (%0d bytes)",
                 cap[0], cap[1], cap[2], cap[3], cap[4], cap[5], cap[6], cap[7], cap[8], capn);

        if (errors == 0) $display("PASS: groovy_features_tb");
        else begin $display("FAIL: groovy_features_tb (%0d errors)", errors); $fatal(1); end
        $finish;
    end
endmodule
