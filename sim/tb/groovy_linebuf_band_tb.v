// SPDX-License-Identifier: GPL-2.0-or-later
// STRICT golden tb reproducing the HW scaler bug: with PERFECT memory, the output
// shows the WRONG source line (HW: row 0 displayed band 4, not band 0). Uses the
// ddr3video/diag config (HREP=4 VREP=3 HSH=2, SINGLE_WORD=1), realistic two clocks, a
// horizontal-BAND source, runs several frames, and checks EVERY output pixel against
// band_color(vcount/VREP) - the sim mirror of the HW band check. Prints the first
// mismatches with read_idx/next_line so the fetch-vs-scan phase error is visible.
`timescale 1ns/1ps
`default_nettype none
module groovy_linebuf_band_tb;
    localparam SRC_W=16, SRC_H=24, HREP=4, VREP=3, HSH=2;
    localparam OUT_W=SRC_W*HREP, OUT_H=SRC_H*VREP;          // 64 x 72
    localparam HTOTAL=OUT_W+20, VTOTAL=OUT_H+6;
    localparam LINE_W=128, LW=7, AW=26;

    reg pix_clk=0; always #6.7 pix_clk=~pix_clk;   // ~74.6 MHz
    reg pclk=0;    always #5.0 pclk=~pclk;          // 100 MHz
    reg pix_rst=1, pclk_rst=1;

    function [15:0] band_color; input [15:0] srow;
        reg [2:0] b; begin
            b = srow / (SRC_H/8);                  // SRC_H/8 = 3 rows per band
            case (b)
              3'd0:band_color=16'hF800;3'd1:band_color=16'h07E0;3'd2:band_color=16'h001F;
              3'd3:band_color=16'hFFE0;3'd4:band_color=16'h07FF;3'd5:band_color=16'hF81F;
              3'd6:band_color=16'hFFFF;default:band_color=16'h8410;
            endcase
        end
    endfunction

    wire rd; wire [AW-1:0] addr; reg busy=0, data_ready=0; reg [15:0] dout=0;
    reg [15:0] hcount=0, vcount=0; reg de=0, line_start=0, frame_start=0;
    wire [15:0] pix_rgb; wire fetch_active;
    wire dbg_lbwe; wire [15:0] dbg_lbdata, dbg_fillline;

    groovy_linebuf_reader #(.LINE_W(LINE_W), .LW_ADDR(LW), .DDR_AW(AW),
        .SINGLE_WORD(1), .H_REPL(HREP), .V_REPL(VREP), .H_SH(HSH)) dut (
        .pix_clk(pix_clk), .pix_rst(pix_rst), .h_active(SRC_W[15:0]), .v_active(SRC_H[15:0]),
        .hcount(hcount), .vcount(vcount), .de(de),
        .line_start(line_start), .frame_start(frame_start), .pix_rgb565(pix_rgb),
        .pclk(pclk), .pclk_rst(pclk_rst), .base_addr(26'd0),
        .rd(rd), .addr(addr), .busy(busy), .data_ready(data_ready),
        .dout128(128'd0), .dout(dout), .fetch_active(fetch_active),
        .dbg_lbwe(dbg_lbwe), .dbg_lbdata(dbg_lbdata), .dbg_fillline(dbg_fillline));

    // PERFECT memory: returns band_color(addr/SRC_W). 4-cyc latency.
    reg [AW-1:0] raddr_l; integer dly=0;
    always @(posedge pclk) begin
        data_ready <= 1'b0;
        if (rd) begin raddr_l <= addr; dly <= 4; busy <= 1'b1; end
        else if (dly > 0) begin
            dly <= dly - 1;
            if (dly==1) begin dout <= band_color(raddr_l / SRC_W); data_ready<=1'b1; busy<=1'b0; end
        end
    end

    localparam VB = VTOTAL - OUT_H;
    reg [15:0] vraw=0; reg run=0; wire active_line = (vraw >= VB);
    always @(posedge pix_clk) if (run) begin
        if (hcount==HTOTAL-1) begin hcount<=0; vraw<=(vraw==VTOTAL-1)?0:vraw+1; end
        else hcount<=hcount+1;
    end
    always @(*) begin
        vcount      = active_line ? (vraw-VB) : 16'd0;
        de          = run && active_line && (hcount < OUT_W);
        line_start  = run && (hcount==0);
        frame_start = run && (hcount==0) && (vraw==0);
    end

    // golden check, expected delayed 2 pix_clk to match the DUT read pipeline.
    reg [15:0] eh[0:2], ev[0:2]; reg eact[0:2]; integer i;
    always @(posedge pix_clk) begin
        eh[0]<=hcount; ev[0]<=vcount; eact[0]<=(de && hcount<OUT_W);
        for (i=1;i<3;i=i+1) begin eh[i]<=eh[i-1]; ev[i]<=ev[i-1]; eact[i]<=eact[i-1]; end
    end
    localparam PIPE=2;
    integer errors=0, checked=0; reg done=0;
    always @(posedge pix_clk) if (run && !done && eact[PIPE] && eh[PIPE]>=PIPE) begin
        checked = checked + 1;
        if (pix_rgb !== band_color(ev[PIPE]/VREP)) begin
            if (errors < 12)
                $display("MISMATCH out(h=%0d,v=%0d) got=%04x exp=%04x srcrow=%0d band=%0d | disp_line=%0d sel_idx=%0d sel_valid=%0d next_line=%0d fill_idx=%0d",
                    eh[PIPE], ev[PIPE], pix_rgb, band_color(ev[PIPE]/VREP),
                    ev[PIPE]/VREP, (ev[PIPE]/VREP)/(SRC_H/8), dut.disp_line, dut.sel_idx, dut.sel_valid, dut.next_line, dut.fill_idx);
            errors = errors + 1;
        end
    end

    initial begin
        repeat (4) @(negedge pclk); pclk_rst=0; pix_rst=0;
        repeat (4) @(negedge pix_clk); run=1;
        repeat (4*VTOTAL*HTOTAL + 100) @(negedge pix_clk);
        done=1;
        $display("RESULT: %0d errors / %0d checked", errors, checked);
        if (errors==0) $display("PASS: band_tb"); else $display("FAIL: band_tb");
        $finish;
    end
    initial begin #50000000; $display("TIMEOUT"); $finish; end
endmodule
`default_nettype wire
