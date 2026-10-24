// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - groovy_audio: CMD_AUDIO bytes in, PT8211 serial stream out, decoded the
// way the DAC reads it (DIN and WS sampled on BCK rising edges, 16 bits per channel, MSB
// first, WS low = right as heard on the board). Checks the exact L/R word sequence, the 48 kHz sample period,
// silence + one counted underrun once the buffer is dry, and mono duplication.
`timescale 1ns/1ps
module groovy_audio_tb;
    reg clk = 0; always #10 clk = ~clk;          // 50 MHz
    reg rst = 1;
    reg [1:0] rate = 2'd3, chan = 2'd2;
    reg start = 0; reg [15:0] size = 0; reg in_valid = 0; reg [7:0] in_data = 0;
    wire receiving, bck, ws, din, pa_en, playing;
    wire [15:0] und, ovf, tmo; wire [12:0] level;
    groovy_audio #(.AW(12), .PREROLL(64)) dut (
        .clk(clk), .rst(rst), .cfg_rate(rate), .cfg_chan(chan),
        .start(start), .size_bytes(size), .in_valid(in_valid), .in_data(in_data),
        .receiving(receiving), .hp_bck(bck), .hp_ws(ws), .hp_din(din), .pa_en(pa_en),
        .playing(playing), .underruns(und), .overflows(ovf), .rx_timeouts(tmo), .level(level));

    integer errs = 0, k;
    task send_audio(input integer n_words, input integer base);
        integer i; reg [15:0] w; begin
        @(posedge clk); start <= 1; size <= n_words * 2; @(posedge clk); start <= 0;
        for (i = 0; i < n_words; i = i + 1) begin
            w = base + i;
            @(posedge clk); in_valid <= 1; in_data <= w[7:0];
            @(posedge clk); in_data <= w[15:8];
            @(posedge clk); in_valid <= 0;                  // a gap, as on the wire
        end
        end
    endtask

    // ---- DAC-side decoder
    reg ws_q = 1; reg [15:0] acc = 0; integer nb = 0;
    integer got_l [0:1023]; integer got_r [0:1023]; integer nl = 0, nr = 0, n_rt = 0;
    real t_first = -1, t_last = 0;
    always @(posedge bck) begin
        if (ws != ws_q) begin
            if (nb == 16) begin
                // PT8211: WS low = RIGHT (first in the frame), WS high = left
                if (ws_q == 0) begin got_r[nl] = acc; end
                else begin got_l[nl] = acc; nl = nl + 1; nr = nl; end
                if (ws_q == 1) begin if (t_first < 0) t_first = $realtime; t_last = $realtime; n_rt = n_rt + 1; end
            end
            nb = 0; acc = 0;
        end
        acc = {acc[14:0], din};  nb = nb + 1;
        ws_q = ws;
    end

    integer first_nz, i0, nz;
    initial begin
        repeat (5) @(posedge clk); rst = 0;
        // ---------------- stereo: words L,R,L,R...: L = 0x1000+2i, R = 0x1000+2i+1
        send_audio(400, 16'h1000);
        #(400.0 / 2 * 20833.3 + 300000);
        // first decoded pair carrying data
        first_nz = -1;
        for (k = 0; k < nl; k = k + 1) if (first_nz < 0 && got_l[k] != 0) first_nz = k;
        nz = 0;
        for (k = first_nz; k < nl && k < nr; k = k + 1) begin
            if (got_l[k] == 0 && got_r[k] == 0) begin end
            else begin
                if (got_l[k] != 16'h1000 + 2*nz || got_r[k] != 16'h1000 + 2*nz + 1) begin
                    if (errs < 6) $display("pair %0d: got L=%h R=%h want %h %h", nz, got_l[k], got_r[k], 16'h1000 + 2*nz, 16'h1000 + 2*nz + 1);
                    errs = errs + 1;
                end
                nz = nz + 1;
            end
        end
        $display("stereo: %0d pairs played (want 200), underruns=%0d overflows=%0d timeouts=%0d, sample period %.1f ns (48 kHz = 20833.3)",
                 nz, und, ovf, tmo, (t_last - t_first) / (n_rt - 1));
        if (nz != 200) errs = errs + 1;
        if (und != 1) begin errs = errs + 1; $display("underruns %0d, want exactly 1 (end of data)", und); end
        if ((t_last - t_first) / (n_rt - 1) < 20800 || (t_last - t_first) / (n_rt - 1) > 20870) errs = errs + 1;
        if (!pa_en) errs = errs + 1;
        // ---------------- mono: each word on both channels
        chan = 2'd1;  i0 = nl;
        send_audio(100, 16'h4000);
        #(100.0 * 20833.3 + 300000);
        nz = 0;
        for (k = i0; k < nl && k < nr; k = k + 1)
            if (got_l[k] != 0) begin
                if (got_l[k] != 16'h4000 + nz || got_r[k] != got_l[k]) begin
                    if (errs < 10) $display("mono %0d: L=%h R=%h want %h", nz, got_l[k], got_r[k], 16'h4000 + nz);
                    errs = errs + 1;
                end
                nz = nz + 1;
            end
        $display("mono: %0d samples played (want 100)", nz);
        if (nz != 100) errs = errs + 1;
        if (errs == 0) $display("PASS: groovy_audio_tb");
        else           $display("FAIL: groovy_audio_tb (%0d errors)", errs);
        $finish;
    end
endmodule
