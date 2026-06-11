// SPDX-License-Identifier: GPL-2.0-or-later
// Self-checking tb for the Gowin-model groovy_pll_solver (Rung 4b).
// Brute-forces an independent reference with the SAME model + tie-break order
// (idiv ascending, strict err<best, smallest valid odiv).
`timescale 1ns/1ps
module groovy_pll_solver_tb;
    reg clk = 0;
    always #5 clk = ~clk;

    localparam integer FREF=27000, VCO_MIN=400000, VCO_MAX=1200000,
                       PFD_MIN=3000, IDIV_MAX=64, FBDIV_MAX=64, TH=5000;

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

    integer ODIV [0:10];
    initial begin
        ODIV[0]=2; ODIV[1]=4; ODIV[2]=8; ODIV[3]=16; ODIV[4]=32; ODIV[5]=48;
        ODIV[6]=64; ODIV[7]=80; ODIV[8]=96; ODIV[9]=112; ODIV[10]=128;
    end

    // reference brute force (Gowin model)
    integer ref_found, ref_idiv, ref_fbdiv, ref_odiv, ref_clk, ref_err;
    task ref_solve; input [31:0] tgt;
        integer i, oi, fb, clko, fpfd, od, e, vco;
    begin
        ref_found=0; ref_err=32'h7FFFFFFF;
        ref_idiv=1; ref_fbdiv=1; ref_odiv=2; ref_clk=0;
        for (i=1; i<=IDIV_MAX; i=i+1) begin
            fpfd = FREF/i;
            fb   = (tgt*i + FREF/2)/FREF;
            if (fpfd>=PFD_MIN && fb>=1 && fb<=FBDIV_MAX) begin
                clko = (FREF*fb)/i;
                od = 0;
                for (oi=10; oi>=0; oi=oi-1) begin
                    vco = clko*ODIV[oi];
                    if (vco>=VCO_MIN && vco<=VCO_MAX) od = ODIV[oi];
                end
                if (od != 0) begin
                    e = (clko>=tgt) ? (clko-tgt) : (tgt-clko);
                    if (e < ref_err) begin
                        ref_err=e; ref_idiv=i; ref_fbdiv=fb; ref_odiv=od;
                        ref_clk=clko; ref_found=1;
                    end
                end
            end
        end
    end endtask

    task run_solver; input [31:0] f;
    begin
        @(negedge clk); fout_khz=f; start=1;
        @(negedge clk); start=0;
        wait (done); @(negedge clk);
    end endtask

    task check; input [31:0] f; input [127:0] name;
        reg exp_ok;
    begin
        ref_solve(f); run_solver(f);
        if (!ref_found) begin
            if (ok) begin $display("FAIL: %0s %0d unreachable but ok=1", name, f); errors=errors+1; end
        end else begin
            exp_ok = (ref_err <= TH);
            if (idiv!==ref_idiv || fbdiv!==ref_fbdiv || odiv!==ref_odiv ||
                achieved_khz!==ref_clk || error_khz!==ref_err || ok!==exp_ok) begin
                $display("FAIL: %0s %0d: DUT idiv=%0d fbdiv=%0d odiv=%0d clk=%0d err=%0d ok=%b | REF %0d/%0d/%0d clk=%0d err=%0d ok=%b",
                    name, f, idiv,fbdiv,odiv,achieved_khz,error_khz,ok,
                    ref_idiv,ref_fbdiv,ref_odiv,ref_clk,ref_err,exp_ok);
                errors=errors+1;
            end else
                $display("  OK %0s: CLKOUT target %0d -> idiv=%0d fbdiv=%0d odiv=%0d => %0d kHz (err %0d, VCO=%0d, ok=%b)",
                    name, f, idiv, fbdiv, odiv, achieved_khz, error_khz, achieved_khz*odiv, ok);
        end
    end endtask

    initial begin
        rst=1; start=0; fout_khz=0;
        @(negedge clk); @(negedge clk); rst=0;

        check(32'd371250, "720p serial (74.25x5)");   // expect exact (idiv4 fbdiv55 odiv2)
        check(32'd134000, "15kHz 26.8MHz x5");
        check(32'd125875, "VGA 25.175 x5");
        check(32'd250000, "50 MHz serial");
        check(32'd500000, "100 MHz serial");
        check(32'd1000,   "1 MHz (unreachable: VCO/odiv floor)");

        if (errors==0) $display("PASS: groovy_pll_solver_tb");
        else begin $display("FAIL: groovy_pll_solver_tb (%0d errors)", errors); $fatal(1); end
        $finish;
    end
endmodule
