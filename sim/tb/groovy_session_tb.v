// SPDX-License-Identifier: GPL-2.0-or-later
// Self-checking testbench for rtl/core/groovy_session.v (CMD_INIT / CMD_CLOSE)
`timescale 1ns/1ps
module groovy_session_tb;
    reg clk = 0;
    always #5 clk = ~clk;

    reg        rst, init_valid, close_valid;
    reg  [7:0] init_lz4, init_sound_rate, init_sound_chan, init_rgb_mode;
    wire       session_active, cfg_lz4, new_session, end_session;
    wire [1:0] cfg_sound_rate, cfg_sound_chan, cfg_rgb_mode;
    wire [2:0] cfg_bytes_per_pixel;
    integer    errors = 0;

    groovy_session dut (
        .clk(clk), .rst(rst),
        .init_valid(init_valid), .init_lz4(init_lz4),
        .init_sound_rate(init_sound_rate), .init_sound_chan(init_sound_chan),
        .init_rgb_mode(init_rgb_mode), .close_valid(close_valid),
        .session_active(session_active), .cfg_lz4(cfg_lz4),
        .cfg_sound_rate(cfg_sound_rate), .cfg_sound_chan(cfg_sound_chan),
        .cfg_rgb_mode(cfg_rgb_mode), .new_session(new_session),
        .end_session(end_session), .cfg_bytes_per_pixel(cfg_bytes_per_pixel));

    task do_init; input [7:0] lz4, sr, ch, rgb;
    begin
        @(negedge clk); init_valid=1; init_lz4=lz4; init_sound_rate=sr;
                        init_sound_chan=ch; init_rgb_mode=rgb;
        @(negedge clk); init_valid=0;
    end endtask

    task do_close;
    begin
        @(negedge clk); close_valid=1;
        @(negedge clk); close_valid=0;
    end endtask

    initial begin
        rst=1; init_valid=0; close_valid=0;
        init_lz4=0; init_sound_rate=0; init_sound_chan=0; init_rgb_mode=0;
        @(negedge clk); @(negedge clk); rst=0;
        @(negedge clk);
        if (session_active) begin $display("FAIL: active after reset"); errors=errors+1; end

        // INIT: lz4=1, 48000(3), 2ch, RGB565(2)
        do_init(8'd1, 8'd3, 8'd2, 8'd2);
        @(negedge clk);
        if (!session_active || !cfg_lz4 || cfg_sound_rate!==2'd3 ||
            cfg_sound_chan!==2'd2 || cfg_rgb_mode!==2'd2 || cfg_bytes_per_pixel!==3'd2) begin
            $display("FAIL: INIT config active=%b lz4=%b sr=%0d ch=%0d rgb=%0d bpp=%0d",
                session_active, cfg_lz4, cfg_sound_rate, cfg_sound_chan,
                cfg_rgb_mode, cfg_bytes_per_pixel);
            errors=errors+1; end

        // RGB888 -> 3 bytes/px, RGBA888 -> 4
        do_init(8'd0, 8'd0, 8'd1, 8'd0); @(negedge clk);
        if (cfg_rgb_mode!==2'd0 || cfg_bytes_per_pixel!==3'd3 || cfg_lz4!==1'b0) begin
            $display("FAIL: RGB888 bpp=%0d lz4=%b", cfg_bytes_per_pixel, cfg_lz4); errors=errors+1; end
        do_init(8'd0, 8'd0, 8'd0, 8'd1); @(negedge clk);
        if (cfg_rgb_mode!==2'd1 || cfg_bytes_per_pixel!==3'd4) begin
            $display("FAIL: RGBA888 bpp=%0d", cfg_bytes_per_pixel); errors=errors+1; end

        // clamping: out-of-range fields -> 0
        do_init(8'd9, 8'd9, 8'd9, 8'd9); @(negedge clk);
        if (cfg_lz4!==1'b0 || cfg_sound_rate!==2'd0 || cfg_sound_chan!==2'd0 ||
            cfg_rgb_mode!==2'd0) begin
            $display("FAIL: clamp lz4=%b sr=%0d ch=%0d rgb=%0d",
                cfg_lz4, cfg_sound_rate, cfg_sound_chan, cfg_rgb_mode);
            errors=errors+1; end

        // CLOSE -> everything cleared
        do_close; @(negedge clk);
        if (session_active || cfg_lz4 || cfg_sound_rate!==2'd0 ||
            cfg_sound_chan!==2'd0 || cfg_rgb_mode!==2'd0) begin
            $display("FAIL: CLOSE did not clear session"); errors=errors+1; end

        if (errors == 0) $display("PASS: groovy_session_tb");
        else begin $display("FAIL: groovy_session_tb (%0d errors)", errors); $fatal(1); end
        $finish;
    end
endmodule
