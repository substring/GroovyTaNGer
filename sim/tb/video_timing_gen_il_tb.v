// SPDX-License-Identifier: GPL-2.0-or-later
// Self-checking testbench for rtl/generic/video/video_timing_gen_il.v, on gwline's real
// 15 kHz raster (VIDEO_MODE 3: 1716 x 262, 1280 active, VSYNC lines 243..245).
//  1. interlace = 0: cycle-for-cycle identical to video_timing_gen.v (all outputs).
//  2. interlace = 1 (raised mid-field): the switch happens on a field boundary and starts
//     with the top field; fields then alternate top (263 lines, field=0) / bottom (262,
//     field=1); every VSYNC start is exactly 262.5 lines after the previous one; the top
//     field's VSYNC starts and ends at h_total/2; HSYNC and DE windows are unchanged and
//     each field has 240 active lines.
//  3. interlace back to 0: progressive again from the next field boundary (field = 0,
//     262 lines).
`timescale 1ns/1ps
module video_timing_gen_il_tb;
    reg clk = 0;
    always #5 clk = ~clk;

    localparam [15:0] HT=1716, HA=1280, HSB=1360, HSE=1488;
    localparam [15:0] VT=262,  VA=240,  VSB=243,  VSE=246;
    localparam integer HALF = 858;

    reg rst = 1, il = 0;
    wire [15:0] hc, vc, hc_r, vc_r;
    wire hs, vs, de, ls, fs, fld, hs_r, vs_r, de_r, ls_r, fs_r;
    integer errors = 0;

    video_timing_gen_il dut (
        .clk(clk), .rst(rst), .en(1'b1), .interlace(il),
        .h_total(HT), .h_active(HA), .h_sync_begin(HSB), .h_sync_end(HSE),
        .v_total(VT), .v_active(VA), .v_sync_begin(VSB), .v_sync_end(VSE),
        .h_sync_pos(1'b0), .v_sync_pos(1'b0),
        .hcount(hc), .vcount(vc), .hsync(hs), .vsync(vs), .de(de),
        .line_start(ls), .frame_start(fs), .field(fld));
    video_timing_gen ref_gen (
        .clk(clk), .rst(rst), .en(1'b1),
        .h_total(HT), .h_active(HA), .h_sync_begin(HSB), .h_sync_end(HSE),
        .v_total(VT), .v_active(VA), .v_sync_begin(VSB), .v_sync_end(VSE),
        .h_sync_pos(1'b0), .v_sync_pos(1'b0),
        .hcount(hc_r), .vcount(vc_r), .hsync(hs_r), .vsync(vs_r), .de(de_r),
        .line_start(ls_r), .frame_start(fs_r));

    // ---- phase 1: progressive == reference
    integer cyc = 0, phase = 1;
    always @(negedge clk) if (!rst && phase == 1) begin
        cyc = cyc + 1;
        if ({hc, vc, hs, vs, de, ls, fs, fld} !== {hc_r, vc_r, hs_r, vs_r, de_r, ls_r, fs_r, 1'b0}) begin
            if (errors < 5) $display("FAIL: progressive differs from video_timing_gen at cycle %0d (h=%0d v=%0d)", cyc, hc, vc);
            errors = errors + 1;
        end
    end

    // ---- field bookkeeping (all phases): field lengths, VSYNC spacing, DE lines
    integer t = 0, last_vs_t = -1, last_fs_t = -1, n_vs = 0, n_fs = 0;
    integer de_lines = 0, vs_ref_line;  reg vs_q = 1, last_fld = 1;
    integer field_lines [0:15];  integer field_val [0:15];  integer field_de [0:15];
    integer vs_gap [0:15];  integer vs_h0 [0:15], vs_h1 [0:15];
    always @(posedge clk) if (!rst) begin
        t = t + 1;
        if (!vs && vs_q) begin                           // VSYNC start (active low)
            if (n_vs < 16) begin vs_gap[n_vs] = last_vs_t < 0 ? 0 : t - last_vs_t;  vs_h0[n_vs] = hc; end
            last_vs_t = t;
        end
        if (vs && !vs_q && n_vs < 16) begin vs_h1[n_vs] = hc;  n_vs = n_vs + 1; end
        vs_q = vs;
        if (fs) begin                                    // first pixel of a field
            if (last_fs_t >= 0 && n_fs < 16) begin
                field_lines[n_fs] = (t - last_fs_t) / HT;  field_val[n_fs] = last_fld;
                field_de[n_fs] = de_lines;  n_fs = n_fs + 1;
            end
            last_fs_t = t;  last_fld = fld;  de_lines = 0;
        end
        if (de && hc == 0) de_lines = de_lines + 1;
    end

    integer k, n_fs_il0, n_vs_il0;
    initial begin
        repeat (3) @(negedge clk);  rst = 0;
        // phase 1: two progressive frames, then raise interlace mid-frame
        repeat (2 * HT * VT + 1000 * HT + 17) @(negedge clk);
        phase = 2;  il = 1;
        n_fs_il0 = n_fs;  n_vs_il0 = n_vs;
        repeat (6 * HT * VT + 3 * HT) @(negedge clk);
        il = 0;
        repeat (3 * HT * VT) @(negedge clk);

        // the field during which interlace was raised (index n_fs_il0) is still
        // progressive; then top, bottom, top, bottom ... ; then progressive again
        for (k = 0; k < n_fs; k = k + 1)
            $display("field %0d: %0d lines, field=%0d, %0d DE lines", k, field_lines[k], field_val[k], field_de[k]);
        for (k = 0; k < n_vs; k = k + 1)
            $display("vsync %0d: start h=%0d end h=%0d, %0d clocks after the previous (%0d.%0d lines)",
                     k, vs_h0[k], vs_h1[k], vs_gap[k], vs_gap[k] / HT, (vs_gap[k] % HT) * 10 / HT);

        if (field_lines[n_fs_il0] != VT || field_val[n_fs_il0] != 0) begin
            $display("FAIL: the field where interlace was raised must stay progressive"); errors = errors + 1; end
        for (k = n_fs_il0 + 1; k < n_fs_il0 + 7; k = k + 1) begin
            if (field_val[k] != ((k - n_fs_il0 - 1) % 2)) begin
                $display("FAIL: field %0d has field=%0d", k, field_val[k]); errors = errors + 1; end
            if (field_lines[k] != (field_val[k] ? VT : VT + 1)) begin
                $display("FAIL: field %0d has %0d lines", k, field_lines[k]); errors = errors + 1; end
        end
        for (k = 0; k < n_fs; k = k + 1) if (field_de[k] != VA) begin
            $display("FAIL: field %0d has %0d DE lines", k, field_de[k]); errors = errors + 1; end
        // interlaced VSYNCs (after the first top field's): 262.5 lines apart
        for (k = n_vs_il0 + 2; k < n_vs_il0 + 7; k = k + 1)
            if (vs_gap[k] != HT * VT + HALF) begin
                $display("FAIL: vsync %0d is %0d clocks after the previous, want %0d", k, vs_gap[k], HT * VT + HALF); errors = errors + 1; end
        // back to progressive: the last fields are 262 lines, field=0, VSYNCs 262 apart
        if (field_lines[n_fs - 1] != VT || field_val[n_fs - 1] != 0) begin
            $display("FAIL: not progressive again at the end"); errors = errors + 1; end
        if (vs_gap[n_vs - 1] != HT * VT) begin
            $display("FAIL: last vsync gap %0d", vs_gap[n_vs - 1]); errors = errors + 1; end

        if (errors == 0) $display("PASS: video_timing_gen_il_tb");
        else             $display("FAIL: video_timing_gen_il_tb (%0d errors)", errors);
        $finish;
    end
endmodule
