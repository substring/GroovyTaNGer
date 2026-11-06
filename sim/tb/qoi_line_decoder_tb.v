// SPDX-License-Identifier: MIT
// Self-checking tb for rtl/generic/compression/qoi_line_decoder.v against the C model.
//
// Vectors come from tools/qoiline (qoiline_test --vectors, run by `make qoi_line_decoder_tb`):
// ~1600 lines, RGB888 and RGB565 alternating, widths 1..700, all line kinds of the C test,
// ~3/8 of them corrupted. Checks:
//   - every good line: each pixel equals qoiline_decode's, out_err = 0, out_last on the
//     last one, line_err = 0;
//   - every corrupted line (the C model refuses it): line_err = 1;
//   - every line gives exactly `width` pixels and the next line still decodes (framing);
//   - random gaps on the input and random stalls on the output.
`default_nettype none

module qoi_line_decoder_tb;
`ifndef VDIR
    `define VDIR "sim/build/qoiline"
`endif
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg  [7:0]  bytes [0:2000000];
    reg  [31:0] lines [0:4095];
    reg  [23:0] pix   [0:2000000];

    reg         rst = 1'b1;
    reg  [31:0] li = 0;                  // current line (for the fmt/width inputs)
    wire [31:0] lw = lines[li];
    reg         in_valid = 1'b0;
    reg  [7:0]  in_data = 8'd0;
    wire        in_ready;
    wire        out_valid, out_last, out_err, line_end, line_err, idle;
    wire [23:0] out_data;
    reg         out_ready = 1'b0;

    qoi_line_decoder dut (
        .clk(clk), .rst(rst), .fmt565(lw[16]), .width(lw[15:0]),
        .in_valid(in_valid), .in_data(in_data), .in_ready(in_ready),
        .out_valid(out_valid), .out_data(out_data), .out_last(out_last), .out_err(out_err),
        .out_ready(out_ready), .line_end(line_end), .line_err(line_err), .idle(idle));

    integer seed = 7;
    integer bi = 0, pi = 0, px_in_line = 0, errors = 0, nlines = 0, nbad = 0, npx = 0;
    integer cycles = 0;

    initial begin
        $readmemh({`VDIR, "/in.hex"}, bytes);
        $readmemh({`VDIR, "/lines.hex"}, lines);
        $readmemh({`VDIR, "/px.hex"}, pix);
        repeat (4) @(posedge clk);
        rst <= 1'b0;
    end

    // input: next byte, with random gaps
    always @(posedge clk) if (!rst) begin
        if (in_valid && in_ready) begin
            bi = bi + 1;
            in_valid <= 1'b0;
        end
        if ((!in_valid || in_ready) && bytes[bi] !== 8'bx && ($random(seed) & 3) != 0) begin
            in_valid <= 1'b1;
            in_data  <= bytes[bi];
        end
    end

    // output: random stalls; check pixels and line ends
    always @(posedge clk) if (!rst) begin
        cycles = cycles + 1;
        out_ready <= ($random(seed) & 7) != 0;
        if (out_valid && out_ready) begin
            npx = npx + 1;
            if (!lw[17]) begin
                if (out_data !== pix[pi] || out_err) begin
                    if (errors < 10)
                        $display("FAIL: line %0d px %0d: got %06x err %b, want %06x",
                                 li, px_in_line, out_data, out_err, pix[pi]);
                    errors = errors + 1;
                end
                pi = pi + 1;
            end
            if (out_last !== (px_in_line == lw[15:0] - 1)) begin
                if (errors < 10) $display("FAIL: line %0d px %0d: out_last %b", li, px_in_line, out_last);
                errors = errors + 1;
            end
            px_in_line = px_in_line + 1;
        end
        if (line_end) begin
            if (px_in_line != lw[15:0] || line_err !== lw[17]) begin
                if (errors < 10)
                    $display("FAIL: line %0d (w %0d, 565 %b): %0d pixels, line_err %b, want %b",
                             li, lw[15:0], lw[16], px_in_line, line_err, lw[17]);
                errors = errors + 1;
            end
            nlines = nlines + 1;
            if (line_err) nbad = nbad + 1;
            px_in_line = 0;
            li <= li + 1;
        end
        if (lines[li] == 32'hFFFFFFFF && idle && !in_valid) begin
            $display("qoi_line_decoder_tb: %0d lines (%0d corrupted), %0d pixels, %0d cycles: %s",
                     nlines, nbad, npx, cycles, errors ? "FAIL" : "PASS");
            $finish;
        end
        if (cycles > 20000000) begin
            $display("FAIL: timeout at line %0d, byte %0d", li, bi);
            $finish;
        end
    end
endmodule

`default_nettype wire
