// SPDX-License-Identifier: GPL-2.0-or-later
// Self-checking tb: groovy_pixel_reader + groovy_vram, 4x2 source scaled x2 -> 8x4.
`timescale 1ns/1ps
module groovy_pixel_reader_tb;
    reg clk=0; always #5 clk=~clk;
    reg  [15:0] hcount, vcount;
    reg         de, hsync, vsync;
    reg  [11:0] native_w;
    reg  [16:0] recip_h, recip_v;
    wire [3:0]  raddr;
    wire [15:0] rdata;
    wire [7:0]  r,g,b;
    wire        de_o, hs_o, vs_o;
    integer errors=0;

    reg        we; reg [3:0] waddr; reg [15:0] wdata;

    groovy_vram #(.DEPTH(8), .ADDR_W(4)) u_vram (
        .clk_w(clk), .we(we), .waddr(waddr), .wdata(wdata),
        .clk_r(clk), .raddr(raddr), .rdata(rdata));

    groovy_pixel_reader #(.ADDR_W(4)) dut (
        .clk(clk), .hcount(hcount), .vcount(vcount),
        .de(de), .hsync(hsync), .vsync(vsync),
        .native_w(native_w), .recip_h(recip_h), .recip_v(recip_v),
        .raddr(raddr), .rdata(rdata), .r(r), .g(g), .b(b),
        .de_o(de_o), .hs_o(hs_o), .vs_o(vs_o));

    integer cap=0; reg [7:0] capR [0:63];
    always @(posedge clk) if (de_o) begin capR[cap]<=r; cap<=cap+1; end

    integer i, oy, ox, line; reg [7:0] exp;
    task wr; input [3:0] a; input [15:0] d; begin
        @(negedge clk); we=1; waddr=a; wdata=d; @(negedge clk); we=0; end
    endtask

    initial begin
        de=0; we=0; hsync=0; vsync=0; hcount=0; vcount=0;
        native_w=12'd4; recip_h=17'd32768; recip_v=17'd32768;   // N=2 (ceil(65536/2))
        @(negedge clk); @(negedge clk);

        for (i=0;i<8;i=i+1) wr(i[3:0], i[4:0]<<11);   // mem[i] r=i

        // drive 4 lines x 8 active pixels, de coincident with hcount=0 (real timing)
        for (line=0; line<4; line=line+1) begin
            for (ox=0; ox<8; ox=ox+1) begin
                @(negedge clk); de=1; hcount=ox[15:0]; vcount=line[15:0];
            end
            @(negedge clk); de=0; hcount=0;            // blanking
            @(negedge clk);
        end
        repeat (4) @(negedge clk);

        if (cap !== 32) begin $display("FAIL: captured %0d px exp 32", cap); errors=errors+1; end
        for (oy=0; oy<4; oy=oy+1)
          for (ox=0; ox<8; ox=ox+1) begin
            exp = (((oy>>1)*4)+(ox>>1))*8;
            if (capR[oy*8+ox] !== exp) begin
                $display("FAIL: out(%0d,%0d) r=%0d exp %0d", ox,oy, capR[oy*8+ox], exp);
                errors=errors+1;
            end
          end

        if (errors==0) $display("PASS: groovy_pixel_reader_tb");
        else begin $display("FAIL: groovy_pixel_reader_tb (%0d errors)", errors); $fatal(1); end
        $finish;
    end
endmodule
