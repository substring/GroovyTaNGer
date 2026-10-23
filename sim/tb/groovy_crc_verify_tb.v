// Isolated sim of the CRC store/compare TIMING from ddr3burst_top, with a PERFECT
// behavioural DDR3 (returns exactly what was written). Goal: confirm BAD=0 with
// clean memory (i.e. the CRC pipeline has no systematic offset). Then inject one bad
// word and confirm BAD increments. Mirrors the probe's S_WR/S_RD logic at small size.
`timescale 1ns/1ps
`default_nettype none
module groovy_crc_verify_tb;
    reg clk=0; always #5 clk=~clk;
    reg resetn=0;

    // perfect memory
    localparam LINEW=8, LINES=4, NWORDS=32, PASSES=2;
    reg [15:0] mem [0:NWORDS-1];
    integer inject = -1;   // word addr to corrupt on READ (-1 none)

    function [15:0] patf; input [25:0] a; patf=(({a[15:0]}*16'h9E37)^16'hA5A5); endfunction
    function [25:0] lin_addr; input [15:0] ln; input [15:0] cl; lin_addr=ln*LINEW+cl; endfunction

    // CRC instances
    reg wi,wv,ri,rv; reg [15:0] wd,rd_; wire [31:0] wc,wcn,rc,rcn;
    groovy_crc32 uw(.clk(clk),.rst(~resetn),.init(wi),.valid(wv),.data(wd),.crc(wc),.crc_next(wcn));
    groovy_crc32 ur(.clk(clk),.rst(~resetn),.init(ri),.valid(rv),.data(rd_),.crc(rc),.crc_next(rcn));
    reg [31:0] line_crc [0:255];

    // simple "controller": 1-cycle write, fixed-latency read
    reg wr,rd; reg [25:0] addr; reg [15:0] din; reg [15:0] dout; reg data_ready;
    reg [3:0] rlat=0; reg [25:0] raddr=0;
    always @(posedge clk) begin
        data_ready<=0;
        if (wr) mem[addr]<=din;
        if (rd) begin rlat<=6; raddr<=addr; end
        else if (rlat!=0) begin rlat<=rlat-1; if (rlat==1) begin
            dout <= (raddr==inject) ? (mem[raddr]^16'h0040) : mem[raddr];
            data_ready<=1; end end
    end
    wire busy = (rlat!=0);

    // FSM (mirrors probe)
    localparam S_WR=0,S_RD=1,S_DONE=2; reg [1:0] st=S_WR;
    reg [15:0] wln,wcol,rln,rcol; reg [25:0] rd_issue; reg [7:0] pass;
    reg wsp; reg [15:0] wsl; reg rcp; reg [15:0] rcl;
    reg [23:0] chk; reg [19:0] bad; reg [15:0] firstb;

    always @(posedge clk) begin
        wr<=0; rd<=0; wi<=0; wv<=0; ri<=0; rv<=0;
        if (!resetn) begin
            st<=S_WR; wln<=0;wcol<=0;rln<=0;rcol<=0;rd_issue<=0;pass<=0;
            wsp<=0;rcp<=0;chk<=0;bad<=0;firstb<=16'hFFFF; wi<=1;
        end else case(st)
        S_WR: begin
            if (wsp) begin
                line_crc[wsl[7:0]]<=wc; wsp<=0;
                if (wsl==LINES-1) begin st<=S_RD; rln<=0;rcol<=0;rd_issue<=0;pass<=0; ri<=1; end
                else begin wln<=wsl+1; wcol<=0; wi<=1; end
            end else if (!wr && !busy) begin
                wr<=1; addr<=lin_addr(wln,wcol); din<=patf(lin_addr(wln,wcol));
                wv<=1; wd<=patf(lin_addr(wln,wcol));
                if (wcol==LINEW-1) begin wsp<=1; wsl<=wln; end else wcol<=wcol+1;
            end
        end
        S_RD: begin
            if (rcp) begin
                rcp<=0; chk<=chk+1;
                if (rc!==line_crc[rcl[7:0]]) begin bad<=bad+1; if(firstb==16'hFFFF) firstb<=rcl; end
                ri<=1;
                if (rcl==LINES-1) begin if(pass==PASSES-1) st<=S_DONE; else begin pass<=pass+1; rln<=0;rcol<=0; end end
                else begin rln<=rcl+1; rcol<=0; end
            end else if (data_ready) begin
                rv<=1; rd_<=dout;
                if (rcol==LINEW-1) begin rcp<=1; rcl<=rln; end else rcol<=rcol+1;
            end
            if (rd_issue<NWORDS) begin
                if (!rd && !busy) begin rd<=1; addr<=rd_issue; rd_issue<=(rd_issue==NWORDS-1)?0:rd_issue+1; end
            end
        end
        S_DONE: ;
        endcase
    end

    initial begin #200000; $display("TIMEOUT st=%0d chk=%0d rd_issue=%0d rln=%0d", st,chk,rd_issue,rln); $finish; end
    initial begin
        // first run: clean
        resetn=0; #20; resetn=1;
        wait(st==S_DONE); #10;
        $display("CLEAN: chk=%0d bad=%0d first=%0d", chk, bad, firstb);
        if (bad!=0) $display("  *** FAIL: clean memory should give bad=0");
        else        $display("  OK: clean memory bad=0");
        // second run: inject one bad word at addr 10 (line 1, col 2)
        inject=10; resetn=0; #20; resetn=1;
        wait(st==S_DONE); #10;
        $display("INJECT@10: chk=%0d bad=%0d first=%0d (expect bad>0, first=1)", chk, bad, firstb);
        if (bad==0) $display("  *** FAIL: injected error not detected");
        else        $display("  OK: injected error detected, first bad line=%0d", firstb);
        if (bad!=0 && firstb==1) $display("PASS: groovy_crc_verify_tb");
        else                     $display("FAIL: groovy_crc_verify_tb");
        $finish;
    end
endmodule
`default_nettype wire
