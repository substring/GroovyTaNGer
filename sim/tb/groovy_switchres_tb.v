// SPDX-License-Identifier: GPL-2.0-or-later
// Self-checking tb for groovy_switchres (Rung 4a compute + report).
// Feeds a 6.7 MHz (15 kHz-class) modeline as an IEEE-754 double, runs the
// pclk->kHz->superres->solver chain, and checks the 25-byte GTSR descriptor.
`timescale 1ns/1ps
module groovy_switchres_tb;
    reg clk = 0;
    always #5 clk = ~clk;            // fast: parser + streamer
    reg clk_slow = 0;
    always #15 clk_slow = ~clk_slow; // slow: PLL solver (distinct rate to exercise CDC)

    localparam integer FREF = 27000;

    reg        rst, switchres_valid, send;
    reg [63:0] sr_pclk;
    reg [15:0] sr_h_total, sr_v_total;
    wire       out_valid, out_last, busy, result_valid, ok;
    wire [7:0] out_data;
    wire [6:0] idiv, fbdiv; wire [7:0] odiv; wire [31:0] achieved_khz;
    integer    errors = 0, k;

    groovy_switchres dut (
        .clk(clk), .clk_slow(clk_slow), .rst(rst),
        .switchres_valid(switchres_valid), .sr_pclk(sr_pclk),
        .sr_h_total(sr_h_total), .sr_v_total(sr_v_total),
        .send(send), .out_valid(out_valid), .out_data(out_data),
        .out_last(out_last), .out_ready(1'b1), .busy(busy),
        .result_valid(result_valid), .idiv(idiv), .fbdiv(fbdiv), .odiv(odiv),
        .achieved_khz(achieved_khz), .ok(ok));

    reg [7:0] cap [0:31];
    integer   capn = 0;
    always @(posedge clk) if (!rst && out_valid) begin cap[capn]=out_data; capn=capn+1; end

    function [31:0] le32; input integer base; begin
        le32 = {cap[base+3], cap[base+2], cap[base+1], cap[base+0]}; end endfunction
    function [15:0] le16; input integer base; begin
        le16 = {cap[base+1], cap[base+0]}; end endfunction

    integer serial, ach;
    initial begin
        rst=1; switchres_valid=0; send=0; sr_pclk=0; sr_h_total=0; sr_v_total=0;
        @(negedge clk); @(negedge clk); rst=0;

        // 15 kHz-class modeline: 6.7 MHz, h_total=426, v_total=262
        sr_pclk = $realtobits(6.7); sr_h_total = 16'd426; sr_v_total = 16'd262;
        @(negedge clk); switchres_valid=1; @(negedge clk); switchres_valid=0;

        wait (result_valid); @(negedge clk);
        @(negedge clk); send=1; @(negedge clk); send=0;
        wait (capn >= 25); @(negedge clk);

        // magic 'GTSR'
        if (cap[0]!==8'h47||cap[1]!==8'h54||cap[2]!==8'h53||cap[3]!==8'h52) begin
            $display("FAIL: magic %h%h%h%h", cap[0],cap[1],cap[2],cap[3]); errors=errors+1; end
        if (le32(4)  !== 32'd6700)  begin $display("FAIL: pclk_khz=%0d (exp 6700)", le32(4)); errors=errors+1; end
        if (cap[8]   !== 8'd4)      begin $display("FAIL: n=%0d (exp 4)", cap[8]); errors=errors+1; end
        if (le32(9)  !== 32'd26800) begin $display("FAIL: pclk_out=%0d (exp 26800)", le32(9)); errors=errors+1; end
        if (le16(21) !== 16'd426)   begin $display("FAIL: h_total=%0d", le16(21)); errors=errors+1; end
        if (le16(23) !== 16'd262)   begin $display("FAIL: v_total=%0d", le16(23)); errors=errors+1; end
        if (cap[20]  !== 8'd1)      begin $display("FAIL: ok=%0d (exp 1)", cap[20]); errors=errors+1; end

        // coeffs must reproduce the achieved PIXEL clock (Gowin model):
        //   serial CLKOUT = FREF*fbdiv/idiv ; pixel = serial/5 (odiv only sets VCO)
        serial = (FREF * cap[14]) / cap[13];
        ach    = serial / 5;
        if (ach !== le32(16)) begin
            $display("FAIL: coeffs idiv=%0d fbdiv=%0d -> serial %0d -> pixel %0d, reported %0d",
                     cap[13], cap[14], serial, ach, le32(16)); errors=errors+1; end

        $display("  GTSR: pclk=%0d kHz n=%0d -> out=%0d kHz | idiv=%0d fbdiv=%0d odiv=%0d -> %0d kHz ok=%0d",
                 le32(4), cap[8], le32(9), cap[13], cap[14], cap[15], le32(16), cap[20]);

        if (errors==0) $display("PASS: groovy_switchres_tb");
        else begin $display("FAIL: groovy_switchres_tb (%0d errors)", errors); $fatal(1); end
        $finish;
    end
endmodule
