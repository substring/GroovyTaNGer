// SPDX-License-Identifier: GPL-2.0-or-later
// Self-checking testbench for rtl/core/groovy_mode_change_fsm.v
`timescale 1ns/1ps
module groovy_mode_change_fsm_tb;
    reg clk = 0;
    always #5 clk = ~clk;

    reg  rst, switchres_valid, in_vblank, solver_done, solver_ok, pll_lock;
    wire solver_start, pll_load, video_blank, timing_load, ready, error;
    integer errors = 0;
    integer guard;

    reg saw_blank_before_load;

    groovy_mode_change_fsm dut (
        .clk(clk), .rst(rst),
        .switchres_valid(switchres_valid), .in_vblank(in_vblank),
        .solver_start(solver_start), .solver_done(solver_done), .solver_ok(solver_ok),
        .pll_load(pll_load), .pll_lock(pll_lock),
        .video_blank(video_blank), .timing_load(timing_load),
        .ready(ready), .error(error));

`ifdef DUMP
    initial begin $dumpfile("sim/build/wave.vcd"); $dumpvars(0, groovy_mode_change_fsm_tb); end
`endif

    initial begin
        rst=1; switchres_valid=0; in_vblank=0; solver_done=0; solver_ok=0; pll_lock=0;
        saw_blank_before_load=0;
        @(negedge clk); @(negedge clk);
        rst=0;
        @(negedge clk);
        if (!ready) begin $display("FAIL: not ready at idle"); errors=errors+1; end

        // ---- nominal successful sequence ----
        switchres_valid=1; @(negedge clk); switchres_valid=0;
        // expect solver_start pulse already issued; wait then return solver ok
        @(negedge clk);
        solver_done=1; solver_ok=1; @(negedge clk); solver_done=0; solver_ok=0;

        // FSM should now wait for vblank; assert vblank
        in_vblank=1;
        // watch for pll_load, and ensure blank is asserted no later than load
        guard=0;
        while (!pll_load && guard<20) begin
            @(negedge clk);
            if (video_blank) saw_blank_before_load=1;
            guard=guard+1;
        end
        if (!pll_load) begin $display("FAIL: pll_load never asserted"); errors=errors+1; end
        if (!saw_blank_before_load && !video_blank) begin
            $display("FAIL: video not blanked before PLL load"); errors=errors+1; end
        in_vblank=0;

        // grant lock; expect timing_load then unblank then ready
        pll_lock=1;
        guard=0;
        while (!timing_load && guard<20) begin @(negedge clk); guard=guard+1; end
        if (!timing_load) begin $display("FAIL: timing_load never asserted"); errors=errors+1; end

        guard=0;
        while (!ready && guard<20) begin @(negedge clk); guard=guard+1; end
        if (!ready) begin $display("FAIL: never returned to ready"); errors=errors+1; end
        if (video_blank) begin $display("FAIL: still blanked after completion"); errors=errors+1; end
        pll_lock=0;

        // ---- solver failure path ----
        @(negedge clk);
        switchres_valid=1; @(negedge clk); switchres_valid=0;
        @(negedge clk);
        solver_done=1; solver_ok=0; @(negedge clk); solver_done=0;
        guard=0;
        while (!error && guard<20) begin @(negedge clk); guard=guard+1; end
        if (!error) begin $display("FAIL: solver failure did not raise error"); errors=errors+1; end

        if (errors == 0) $display("PASS: groovy_mode_change_fsm_tb");
        else begin $display("FAIL: groovy_mode_change_fsm_tb (%0d errors)", errors); $fatal(1); end
        $finish;
    end
endmodule
