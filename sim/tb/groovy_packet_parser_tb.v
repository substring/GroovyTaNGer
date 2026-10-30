// SPDX-License-Identifier: GPL-2.0-or-later
// Self-checking testbench for rtl/core/groovy_packet_parser.v
// Exercises every command, both blit length variants, and error cases.
`timescale 1ns/1ps
module groovy_packet_parser_tb;
    reg clk = 0;
    always #5 clk = ~clk;

    reg        rst, in_valid, in_sop, in_eop;
    reg  [7:0] in_data;
    integer    errors = 0;
    integer    i;
    reg  [7:0] sr [0:25];

    wire        cmd_valid, bad_packet;
    wire [7:0]  cmd;
    wire        close_valid, init_valid, switchres_valid, audio_valid;
    wire        get_status_valid, blit_valid, get_version_valid;
    wire [7:0]  init_lz4, init_sound_rate, init_sound_chan, init_rgb_mode;
    wire [63:0] sr_pclk;
    wire [15:0] sr_h_active, sr_h_begin, sr_h_end, sr_h_total;
    wire [15:0] sr_v_active, sr_v_begin, sr_v_end, sr_v_total;
    wire [7:0]  sr_interlace;
    wire [15:0] audio_size;
    wire [31:0] blit_frame, blit_csize;
    wire [7:0]  blit_field;
    wire [15:0] blit_vsync;
    wire        blit_lz4, blit_flag;

    groovy_packet_parser dut (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_data(in_data), .in_sop(in_sop), .in_eop(in_eop),
        .cmd_valid(cmd_valid), .cmd(cmd), .bad_packet(bad_packet),
        .close_valid(close_valid), .init_valid(init_valid),
        .switchres_valid(switchres_valid), .audio_valid(audio_valid),
        .get_status_valid(get_status_valid), .blit_valid(blit_valid),
        .get_version_valid(get_version_valid),
        .init_lz4(init_lz4), .init_sound_rate(init_sound_rate),
        .init_sound_chan(init_sound_chan), .init_rgb_mode(init_rgb_mode),
        .sr_pclk(sr_pclk),
        .sr_h_active(sr_h_active), .sr_h_begin(sr_h_begin), .sr_h_end(sr_h_end),
        .sr_h_total(sr_h_total), .sr_v_active(sr_v_active), .sr_v_begin(sr_v_begin),
        .sr_v_end(sr_v_end), .sr_v_total(sr_v_total), .sr_interlace(sr_interlace),
        .audio_size(audio_size),
        .blit_frame(blit_frame), .blit_field(blit_field), .blit_vsync(blit_vsync),
        .blit_lz4(blit_lz4), .blit_csize(blit_csize), .blit_flag(blit_flag));

`ifdef DUMP
    initial begin $dumpfile("sim/build/wave.vcd"); $dumpvars(0, groovy_packet_parser_tb); end
`endif

    task send_byte; input [7:0] d; input s; input e;
    begin
        @(negedge clk); in_valid=1; in_data=d; in_sop=s; in_eop=e;
        @(negedge clk); in_valid=0; in_sop=0; in_eop=0;
    end endtask

    // call exactly one @(negedge) after the last byte to land on cmd_valid
    task expect_cmd_valid;
    begin
        @(negedge clk);
        if (!cmd_valid) begin
            $display("FAIL: cmd_valid not asserted"); errors = errors + 1; end
    end endtask

    initial begin
        rst=1; in_valid=0; in_sop=0; in_eop=0; in_data=0;
        @(negedge clk); @(negedge clk);
        rst=0;

        // ---- CMD_CLOSE ----
        send_byte(8'd1, 1, 1);
        @(negedge clk);
        if (!cmd_valid || !close_valid || bad_packet) begin
            $display("FAIL: CLOSE"); errors=errors+1; end

        // ---- CMD_GET_STATUS ----
        send_byte(8'd5, 1, 1);
        @(negedge clk);
        if (!get_status_valid) begin $display("FAIL: GET_STATUS"); errors=errors+1; end

        // ---- CMD_GET_VERSION ----
        send_byte(8'd8, 1, 1);
        @(negedge clk);
        if (!get_version_valid) begin $display("FAIL: GET_VERSION"); errors=errors+1; end

        // ---- CMD_INIT ----
        send_byte(8'd2, 1, 0);
        send_byte(8'd1, 0, 0);
        send_byte(8'd3, 0, 0);
        send_byte(8'd2, 0, 0);
        send_byte(8'd2, 0, 1);
        @(negedge clk);
        if (!init_valid || bad_packet) begin $display("FAIL: INIT valid"); errors=errors+1; end
        if (init_lz4!==8'd1 || init_sound_rate!==8'd3 ||
            init_sound_chan!==8'd2 || init_rgb_mode!==8'd2) begin
            $display("FAIL: INIT fields lz4=%0d sr=%0d ch=%0d rgb=%0d",
                init_lz4, init_sound_rate, init_sound_chan, init_rgb_mode);
            errors=errors+1; end

        // ---- CMD_AUDIO, size=0x0102 ----
        send_byte(8'd4, 1, 0);
        send_byte(8'h02, 0, 0);
        send_byte(8'h01, 0, 1);
        @(negedge clk);
        if (!audio_valid || audio_size!==16'h0102) begin
            $display("FAIL: AUDIO size=%h", audio_size); errors=errors+1; end

        // ---- CMD_BLIT raw, 8 bytes ----
        send_byte(8'd7, 1, 0);
        send_byte(8'h01,0,0); send_byte(8'h02,0,0); send_byte(8'h03,0,0); send_byte(8'h04,0,0);
        send_byte(8'h05,0,0);                       // field
        send_byte(8'h06,0,0); send_byte(8'h07,0,1); // vsync LE = 0x0706
        @(negedge clk);
        if (!blit_valid) begin $display("FAIL: BLIT raw valid"); errors=errors+1; end
        if (blit_frame!==32'h04030201 || blit_field!==8'h05 ||
            blit_vsync!==16'h0706 || blit_lz4!==1'b0 || blit_flag!==1'b0) begin
            $display("FAIL: BLIT raw fields frame=%h field=%h vsync=%h lz4=%b flag=%b",
                blit_frame, blit_field, blit_vsync, blit_lz4, blit_flag);
            errors=errors+1; end

        // ---- CMD_BLIT lz4 + frame_delta, 13 bytes ----
        send_byte(8'd7, 1, 0);
        send_byte(8'h10,0,0); send_byte(8'h11,0,0); send_byte(8'h12,0,0); send_byte(8'h13,0,0);
        send_byte(8'h01,0,0);                       // field
        send_byte(8'h20,0,0); send_byte(8'h21,0,0); // vsync = 0x2120
        send_byte(8'h30,0,0); send_byte(8'h31,0,0); send_byte(8'h32,0,0); send_byte(8'h33,0,0); // csize
        send_byte(8'h01,0,1);                       // frame_delta flag
        @(negedge clk);
        if (!blit_valid) begin $display("FAIL: BLIT lz4 valid"); errors=errors+1; end
        if (blit_frame!==32'h13121110 || blit_field!==8'h01 || blit_vsync!==16'h2120 ||
            blit_lz4!==1'b1 || blit_csize!==32'h33323130 || blit_flag!==1'b1) begin
            $display("FAIL: BLIT lz4 fields frame=%h vsync=%h lz4=%b csize=%h flag=%b",
                blit_frame, blit_vsync, blit_lz4, blit_csize, blit_flag);
            errors=errors+1; end

        // ---- CMD_SWITCHRES, 26 bytes ----
        sr[0]=8'd3;
        sr[1]=8'h11; sr[2]=8'h22; sr[3]=8'h33; sr[4]=8'h44;
        sr[5]=8'h55; sr[6]=8'h66; sr[7]=8'h77; sr[8]=8'h88;   // pclk LE
        sr[9]=8'h40;  sr[10]=8'h01;   // h_active = 320
        sr[11]=8'h08; sr[12]=8'h00;   // h_begin  = 8
        sr[13]=8'h28; sr[14]=8'h00;   // h_end    = 40
        sr[15]=8'h90; sr[16]=8'h01;   // h_total  = 400
        sr[17]=8'hF0; sr[18]=8'h00;   // v_active = 240
        sr[19]=8'hF3; sr[20]=8'h00;   // v_begin  = 243
        sr[21]=8'hF6; sr[22]=8'h00;   // v_end    = 246
        sr[23]=8'h06; sr[24]=8'h01;   // v_total  = 262
        sr[25]=8'h00;                 // interlace
        for (i=0;i<26;i=i+1) send_byte(sr[i], (i==0), (i==25));
        @(negedge clk);
        if (!switchres_valid || bad_packet) begin
            $display("FAIL: SWITCHRES valid"); errors=errors+1; end
        if (sr_pclk!==64'h8877665544332211) begin
            $display("FAIL: SWITCHRES pclk=%h", sr_pclk); errors=errors+1; end
        if (sr_h_active!==16'd320 || sr_h_begin!==16'd8 || sr_h_end!==16'd40 ||
            sr_h_total!==16'd400 || sr_v_active!==16'd240 || sr_v_begin!==16'd243 ||
            sr_v_end!==16'd246 || sr_v_total!==16'd262 || sr_interlace!==8'd0) begin
            $display("FAIL: SWITCHRES modeline ha=%0d hb=%0d he=%0d ht=%0d va=%0d vb=%0d ve=%0d vt=%0d il=%0d",
                sr_h_active, sr_h_begin, sr_h_end, sr_h_total,
                sr_v_active, sr_v_begin, sr_v_end, sr_v_total, sr_interlace);
            errors=errors+1; end

        // ---- CMD_BLIT_VSYNC (6), GroovyMAME's 11-byte raw blit: frame 0x01020304,
        //      vsync 0x0105, cSize 0 -> raw (lz4 = 0), field 0 ----
        send_byte(8'd6,1,0);
        send_byte(8'h04,0,0); send_byte(8'h03,0,0); send_byte(8'h02,0,0); send_byte(8'h01,0,0);
        send_byte(8'h05,0,0); send_byte(8'h01,0,0);
        send_byte(8'h00,0,0); send_byte(8'h00,0,0); send_byte(8'h00,0,0); send_byte(8'h00,0,1);
        @(negedge clk);
        if (!blit_valid || bad_packet || blit_frame!==32'h01020304 || blit_vsync!==16'h0105 ||
            blit_field!==8'd0 || blit_lz4!==1'b0 || blit_csize!==32'd0 || blit_flag!==1'b0) begin
            $display("FAIL: CMD 6 raw: v=%b bad=%b fr=%h vs=%h fld=%0d lz4=%b cs=%0d",
                blit_valid, bad_packet, blit_frame, blit_vsync, blit_field, blit_lz4, blit_csize);
            errors=errors+1; end
        // ---- CMD 6 with LZ4: cSize 0x00001234 ----
        send_byte(8'd6,1,0);
        send_byte(8'h09,0,0); send_byte(8'h00,0,0); send_byte(8'h00,0,0); send_byte(8'h00,0,0);
        send_byte(8'h20,0,0); send_byte(8'h00,0,0);
        send_byte(8'h34,0,0); send_byte(8'h12,0,0); send_byte(8'h00,0,0); send_byte(8'h00,0,1);
        @(negedge clk);
        if (!blit_valid || blit_frame!==32'd9 || blit_vsync!==16'h20 || blit_lz4!==1'b1 ||
            blit_csize!==32'h1234) begin
            $display("FAIL: CMD 6 lz4: fr=%0d vs=%h lz4=%b cs=%h", blit_frame, blit_vsync, blit_lz4, blit_csize);
            errors=errors+1; end
        // ---- CMD 6, 7-byte form (no cSize) ----
        send_byte(8'd6,1,0);
        send_byte(8'h0A,0,0); send_byte(8'h00,0,0); send_byte(8'h00,0,0); send_byte(8'h00,0,0);
        send_byte(8'h30,0,0); send_byte(8'h00,0,1);
        @(negedge clk);
        if (!blit_valid || blit_frame!==32'd10 || blit_vsync!==16'h30 || blit_lz4!==1'b0) begin
            $display("FAIL: CMD 6 7-byte form"); errors=errors+1; end
        // ---- error: CMD 6 with a wrong length (1 byte) ----
        send_byte(8'd6, 1, 1);
        @(negedge clk);
        if (!bad_packet || blit_valid) begin $display("FAIL: 1-byte cmd 6 not flagged"); errors=errors+1; end

        // ---- CMD_INIT 4-byte form (rgbMode omitted -> RGB888) ----
        send_byte(8'd2, 1, 0);
        send_byte(8'd1, 0, 0);   // lz4
        send_byte(8'd2, 0, 0);   // sound rate
        send_byte(8'd1, 0, 1);   // sound chan ; no rgb byte
        @(negedge clk);
        if (!init_valid || bad_packet) begin
            $display("FAIL: 4-byte INIT not accepted"); errors=errors+1; end
        if (init_lz4!==8'd1 || init_sound_rate!==8'd2 ||
            init_sound_chan!==8'd1 || init_rgb_mode!==8'd0) begin
            $display("FAIL: 4-byte INIT fields lz4=%0d sr=%0d ch=%0d rgb=%0d (rgb must default 0)",
                init_lz4, init_sound_rate, init_sound_chan, init_rgb_mode);
            errors=errors+1; end

        // ---- error: INIT with genuinely invalid length (3 bytes) ----
        send_byte(8'd2,1,0); send_byte(8'h00,0,0); send_byte(8'h00,0,1);
        @(negedge clk);
        if (!bad_packet || init_valid) begin
            $display("FAIL: 3-byte INIT not flagged"); errors=errors+1; end

        if (errors == 0) $display("PASS: groovy_packet_parser_tb");
        else begin $display("FAIL: groovy_packet_parser_tb (%0d errors)", errors); $fatal(1); end
        $finish;
    end
endmodule
