// SPDX-License-Identifier: GPL-2.0-or-later
// Self-checking testbench for rtl/core/groovy_pll_solver.v
//
// Verifies the hardware search against an independent brute-force reference
// computed in the testbench with the SAME constraints and tie-break order
// (idiv outer 1..IDIV_MAX, odiv inner, strict err<best). This validates the
// solver logic regardless of absolute PLL precision (see the module's
// PRECISION NOTE).
`timescale 1ns/1ps
module groovy_pll_solver_tb;
    reg clk = 0;
    always #5 clk = ~clk;

    localparam integer FREF     = 27000;
    localparam integer VCO_MIN  = 400000;
    localparam integer VCO_MAX  = 1200000;
    localparam integer IDIV_MAX = 4;
    localparam integer TH       = 1000;   // must match DUT THRESHOLD_KHZ default

    reg         rst, start;
    reg  [31:0] fout_khz;
    wire        done, busy, ok;
    wire [6:0]  idiv, fbdiv;
    wire [7:0]  odiv;
    wire [31:0] achieved_khz, error_khz;
    integer     errors = 0;

    groovy_pll_solver dut (
        .clk(clk), .rst(rst), .start(start), .fout_khz(fout_khz),
        .done(done), .busy(busy), .ok(ok),
        .idiv(idiv), .fbdiv(fbdiv), .odiv(odiv),
        .achieved_khz(achieved_khz), .error_khz(error_khz));

    // odiv set (must match DUT)
    integer ODIV [0:10];
    initial begin
        ODIV[0]=2;  ODIV[1]=4;  ODIV[2]=8;  ODIV[3]=16; ODIV[4]=32; ODIV[5]=48;
        ODIV[6]=64; ODIV[7]=80; ODIV[8]=96; ODIV[9]=112; ODIV[10]=128;
    end

    // reference brute force; returns via globals
    integer ref_found, ref_idiv, ref_fbdiv, ref_odiv, ref_ach, ref_err;
    task ref_solve; input [31:0] f;
        integer i, oi, od, fb, fvco, ach, err;
    begin
        ref_found=0; ref_err=32'h7FFFFFFF;
        ref_idiv=1; ref_fbdiv=1; ref_odiv=2; ref_ach=0;
        for (i=1; i<=IDIV_MAX; i=i+1)
            for (oi=0; oi<=10; oi=oi+1) begin
                od = ODIV[oi];
                fb = (f*i*od + FREF/2) / FREF;
                if (fb>=1 && fb<=64) begin
                    fvco = (FREF*fb)/i;
                    if (fvco>=VCO_MIN && fvco<=VCO_MAX) begin
                        ach = fvco/od;
                        err = (ach>=f) ? (ach-f) : (f-ach);
                        if (err < ref_err) begin
                            ref_err=err; ref_idiv=i; ref_fbdiv=fb;
                            ref_odiv=od; ref_ach=ach; ref_found=1;
                        end
                    end
                end
            end
    end endtask

    task run_solver; input [31:0] f;
    begin
        @(negedge clk); fout_khz=f; start=1;
        @(negedge clk); start=0;
        wait (done);
        @(negedge clk);
    end endtask

    task check; input [31:0] f;
        reg exp_ok;
    begin
        ref_solve(f);
        run_solver(f);
        if (ref_found) begin
            exp_ok = (ref_err <= TH);
            if (idiv!==ref_idiv || fbdiv!==ref_fbdiv || odiv!==ref_odiv ||
                achieved_khz!==ref_ach || error_khz!==ref_err || ok!==exp_ok) begin
                $display("FAIL: %0d kHz: DUT idiv=%0d fbdiv=%0d odiv=%0d ach=%0d err=%0d ok=%b | REF idiv=%0d fbdiv=%0d odiv=%0d ach=%0d err=%0d ok=%b",
                    f, idiv, fbdiv, odiv, achieved_khz, error_khz, ok,
                    ref_idiv, ref_fbdiv, ref_odiv, ref_ach, ref_err, exp_ok);
                errors = errors + 1;
            end else
                $display("  OK %0d kHz: idiv=%0d fbdiv=%0d odiv=%0d -> %0d kHz (err %0d, lock=%b)",
                    f, idiv, fbdiv, odiv, achieved_khz, error_khz, ok);
        end else begin
            // unreachable: no valid candidate -> DUT must report ok=0
            if (ok) begin
                $display("FAIL: %0d kHz unreachable but DUT ok=1", f); errors=errors+1;
            end else
                $display("  OK %0d kHz: correctly unreachable (ok=0)", f);
        end
    end endtask

    initial begin
        rst=1; start=0; fout_khz=0;
        @(negedge clk); @(negedge clk);
        rst=0;

        check(32'd25175);   // VGA 640x480@60   (~137 kHz off, locks)
        check(32'd27000);   // exact
        check(32'd30000);   // 6.0 x5
        check(32'd74250);   // 720p60 (exact)
        check(32'd31500);   // exact
        check(32'd40000);
        check(32'd6144);    // low arcade clock
        check(32'd1000);    // unreachable (below min achievable VCO/odiv)

        if (errors == 0) $display("PASS: groovy_pll_solver_tb");
        else begin $display("FAIL: groovy_pll_solver_tb (%0d errors)", errors); $fatal(1); end
        $finish;
    end
endmodule
