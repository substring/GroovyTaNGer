// SPDX-License-Identifier: MIT
// Groovy_Tang - QOI line decoder (generic, vendor-neutral). Spec: docs/qoi_line_format.md.
//
// Decodes a stream of coded lines, each one = 2-byte little-endian header
// (bit 15 = raw, bits 14..0 = payload bytes) + payload, into pixels. Every line restarts
// the QOI state (previous pixel = black, cache unused), so each line is decoded on its own,
// as a beam-racing receiver needs. Golden model: tools/qoiline/qoiline.c (qoiline_decode);
// sim/tb/qoi_line_decoder_tb.v checks this module against it.
//
// Pixel format (fmt565) and line width are INPUTS, sampled with the second header byte of
// every line, so one build decodes RGB888 and RGB565 (CMD_INIT rgbMode) at any width:
//   fmt565 = 0: RGB888, raw payload in the wire order B, G, R; out_data = {r8, g8, b8}
//   fmt565 = 1: RGB565, raw payload 16-bit LE words;       out_data = {8'd0, r5, g6, b5}
//
// Every line gives EXACTLY `width` output pixels, whatever its payload, and consumes
// EXACTLY the header length, so a corrupted line never shifts the next ones. On a
// corrupted line (reserved op 0xFF, an index to a cache entry not written in this line, an op past the end of the payload, more pixels than
// `width`, bytes left over, a raw length that is not width * bytes per pixel, length 0)
// the rest of its payload is skipped, its missing pixels come out as black with out_err = 1,
// and line_err is set with line_end. A line whose last pixel is out but still has payload
// left is also flagged (line_err only: all its pixels were already sent).
//
// Interfaces: valid/ready byte in, valid/ready pixel out (out_last with the line's last
// pixel), one-cycle line_end pulse once the whole line (pixels + payload) is consumed.
// Throughput: one byte per clock, one pixel per clock on runs; an index op takes 2 clocks
// (synchronous cache read). At 50 MHz that is 4x the 100 Mbit link and 5x a 640-px
// line every 63.6 us.
//
// Portability: Verilog-2001, no vendor primitive, synchronous active-high reset. The
// 64 x 24-bit cache is an inferred simple dual-port RAM with a synchronous,
// read-before-write read (the plain template: a block RAM or LUT RAM anywhere; Gowin
// puts it in one BSRAM), never cleared; 64 valid flags, cleared at every line, mark the
// entries written in this line. The encoder only refers to those, so an index to another
// one is a corruption (flagged, as the C model does).
`default_nettype none

module qoi_line_decoder (
    input  wire        clk,
    input  wire        rst,

    input  wire        fmt565,       // 1 = RGB565, 0 = RGB888 (sampled per line)
    input  wire [15:0] width,        // pixels per line, >= 1 (sampled per line)

    input  wire        in_valid,
    input  wire [7:0]  in_data,
    output wire        in_ready,

    output reg         out_valid,
    output reg  [23:0] out_data,
    output reg         out_last,     // with the line's last pixel
    output reg         out_err,      // this pixel is filler of a corrupted line
    input  wire        out_ready,

    output reg         line_end,     // pulse: line fully consumed
    output reg         line_err,     // valid with line_end: the line was corrupted
    output wire        idle          // waiting for the first byte of a line
);
    localparam [3:0] S_H0 = 4'd0, S_H1 = 4'd1, S_OP = 4'd2, S_LUMA = 4'd3, S_RGB = 4'd4,
                     S_IDX = 4'd5, S_RUN = 4'd6, S_RAW = 4'd7, S_DRAIN = 4'd8,
                     S_FILL = 4'd9, S_END = 4'd10;

    reg [3:0]  st;
    reg        f565;                 // format of the current line
    reg [15:0] cnt;                  // pixels still to output in this line
    reg [14:0] blen;                 // payload bytes still to consume
    reg [5:0]  run_left;             // pixels left in a run, minus one
    reg [1:0]  nb;                   // bytes gathered for an RGB / raw pixel
    reg [7:0]  b0, b1, hdr0;
    reg        err;
    reg [7:0]  pr, pg, pb;           // previous pixel, channels in their own width

    // ---- cache: 64 x {r, g, b}, written with every output pixel
    reg [23:0] cache [0:63];
    reg [23:0] cq;                   // synchronous read (read-before-write), see below
    reg [63:0] cvalid;

    // ---- handshakes
    wire step  = !out_valid || out_ready;    // the output register can take a pixel
    wire need  = (st == S_H0) || (st == S_H1) ||
                 (((st == S_OP) || (st == S_LUMA) || (st == S_RGB) || (st == S_RAW) ||
                   (st == S_DRAIN)) && (blen != 15'd0));
    assign in_ready = step && need;
    wire take  = in_valid && in_ready;
    assign idle = (st == S_H0);

    // ---- channel arithmetic, modulo the channel widths
    wire [7:0] mr = f565 ? 8'h1F : 8'hFF;
    wire [7:0] mg = f565 ? 8'h3F : 8'hFF;
    wire [7:0] d  = in_data;

    // QOI_OP_DIFF: each channel + (2-bit field - 2)
    wire [7:0] df_r = (pr + {6'd0, d[5:4]} - 8'd2) & mr;
    wire [7:0] df_g = (pg + {6'd0, d[3:2]} - 8'd2) & mg;
    wire [7:0] df_b = (pb + {6'd0, d[1:0]} - 8'd2) & mr;
    // QOI_OP_LUMA: vg = b0[5:0] - 32; vg' = vg (888) or vg >>> 1 (565); r/b += vg' + nibble - 8
    wire [7:0] lu_vg  = {2'b00, b0[5:0]} - 8'd32;
    wire [7:0] lu_vgp = f565 ? {lu_vg[7], lu_vg[7:1]} : lu_vg;
    wire [7:0] lu_r = (pr + lu_vgp + {4'd0, d[7:4]} - 8'd8) & mr;
    wire [7:0] lu_g = (pg + lu_vg) & mg;
    wire [7:0] lu_b = (pb + lu_vgp + {4'd0, d[3:0]} - 8'd8) & mr;

    // the pixel completed by the current byte, for RGB / raw gathering
    // 565: LE word {d, b0}; 888 raw (wire B, G, R): {d, b1, b0}; 888 OP_RGB (r, g, b): {b0, b1, d}
    wire [15:0] w565 = {d, b0};
    wire [7:0]  g_r = f565 ? {3'd0, w565[15:11]} : ((st == S_RAW) ? d  : b0);
    wire [7:0]  g_g = f565 ? {2'd0, w565[10:5]}  : b1;
    wire [7:0]  g_b = f565 ? {3'd0, w565[4:0]}   : ((st == S_RAW) ? b0 : d);
    wire [1:0]  last_nb = f565 ? 2'd1 : 2'd2;      // index of the pixel's last byte

    // raw payload length for this line's width
    wire [16:0] raw_len = fmt565 ? {width, 1'b0} : ({1'b0, width} + {width, 1'b0});

    // ---- the pixel output this cycle (if step): emit, {er, eg, eb}
    reg        emit;
    reg [7:0]  er, eg, eb;
    always @(*) begin
        emit = 1'b0;  er = pr;  eg = pg;  eb = pb;
        case (st)
        S_OP:   if (take && cnt != 16'd0 && d[7:6] == 2'b01) begin
                    emit = 1'b1;  er = df_r;  eg = df_g;  eb = df_b;
                end
        S_LUMA: if (take) begin emit = 1'b1;  er = lu_r;  eg = lu_g;  eb = lu_b; end
        S_RGB, S_RAW:
                if (take && nb == last_nb) begin emit = 1'b1;  er = g_r;  eg = g_g;  eb = g_b; end
        S_IDX:  begin
                    emit = 1'b1;
                    if (!byp) begin er = cq[23:16];  eg = cq[15:8];  eb = cq[7:0]; end
                end
        S_RUN:  emit = 1'b1;
        default: ;
        endcase
    end

    // The cache write is DELAYED one cycle: the pixel output at cycle t is in {pr, pg, pb}
    // at t+1 and written then, so its hash starts from registers (hashing the freshly
    // computed pixel limited Fmax to ~59 MHz on a GW2A). The only entry a following index
    // op could miss is that pixel's own one (an index to the previous pixel, which the
    // encoder codes as a run, but a decoder must still decode it): `byp` covers it.
    // hash: (r*3 + g*5 + b*7 + 255*11) mod 64, 2805 mod 64 = 53
    /* verilator lint_off UNUSEDSIGNAL */
    wire [7:0] ph8 = pr * 8'd3 + pg * 8'd5 + pb * 8'd7 + 8'd53;    // only [5:0] is used
    /* verilator lint_on UNUSEDSIGNAL */
    wire [5:0] ph  = ph8[5:0];
    reg        wpend;                // {pr, pg, pb} was output last cycle: write it now
    reg        byp;                  // the index op being decoded refers to that pixel
    wire       ix_valid = cvalid[d[5:0]] || (wpend && ph == d[5:0]);

    always @(posedge clk) begin
        if (wpend) cache[ph] <= {pr, pg, pb};
        if (st == S_OP && take) cq <= cache[d[5:0]];    // used only if d is an index op
    end


    always @(posedge clk) begin
        line_end <= 1'b0;
        wpend <= !rst && step && emit;
        if (wpend) cvalid[ph] <= 1'b1;
        if (out_valid && out_ready) out_valid <= 1'b0;

        if (rst) begin
            st <= S_H0;  out_valid <= 1'b0;  out_last <= 1'b0;  out_err <= 1'b0;
            line_err <= 1'b0;  err <= 1'b0;  cnt <= 16'd0;  blen <= 15'd0;
            run_left <= 6'd0;  nb <= 2'd0;  f565 <= 1'b0;
            pr <= 8'd0;  pg <= 8'd0;  pb <= 8'd0;  byp <= 1'b0;
        end else if (step) begin
            if (take && st != S_H0 && st != S_H1) blen <= blen - 15'd1;

            case (st)
            S_H0: if (take) begin hdr0 <= d;  st <= S_H1; end
            S_H1: if (take) begin
                f565 <= fmt565;  cnt <= width;  err <= 1'b0;  cvalid <= 64'd0;
                pr <= 8'd0;  pg <= 8'd0;  pb <= 8'd0;  nb <= 2'd0;
                blen <= {d[6:0], hdr0};
                if ({d[6:0], hdr0} == 15'd0) begin
                    err <= 1'b1;  st <= S_FILL;
                end else if (width == 16'd0) begin
                    err <= 1'b1;  st <= S_DRAIN;
                end else if (d[7]) begin
                    if ({2'b00, d[6:0], hdr0} != raw_len) begin err <= 1'b1;  st <= S_DRAIN; end
                    else st <= S_RAW;
                end else st <= S_OP;
            end
            S_OP: begin
                if (cnt == 16'd0) begin
                    if (blen == 15'd0) st <= S_END;           // line complete
                    else begin err <= 1'b1;  st <= S_DRAIN; end // bytes left over
                end else if (blen == 15'd0) begin
                    err <= 1'b1;  st <= S_FILL;     // payload ended before the line
                end else if (take) begin
                    if (d == 8'hFE) begin nb <= 2'd0;  st <= S_RGB; end
                    else if (d == 8'hFF) begin err <= 1'b1;  st <= S_DRAIN; end
                    else case (d[7:6])
                        2'b00: if (ix_valid) begin
                                   byp <= wpend && ph == d[5:0];  st <= S_IDX;
                               end
                               else begin err <= 1'b1;  st <= S_DRAIN; end
                        2'b01: ;                                    // DIFF: emitted below
                        2'b10: begin b0 <= d;  st <= S_LUMA; end
                        default: begin
                            if ({10'd0, d[5:0]} >= cnt) begin err <= 1'b1;  st <= S_DRAIN; end
                            else begin run_left <= d[5:0];  st <= S_RUN; end
                        end
                    endcase
                end
            end
            S_LUMA: if (blen == 15'd0) begin err <= 1'b1;  st <= S_FILL; end
                    else if (take) st <= S_OP;
            S_RGB, S_RAW: if (blen == 15'd0) begin err <= 1'b1;  st <= S_FILL; end
                    else if (take) begin
                        if (nb == last_nb) begin
                            nb <= 2'd0;
                            if (st == S_RGB) st <= S_OP;
                            else if (cnt == 16'd1) st <= S_END;   // raw length was checked
                        end else begin
                            if (nb == 2'd0) b0 <= d; else b1 <= d;
                            nb <= nb + 2'd1;
                        end
                    end
            S_IDX: st <= S_OP;
            S_RUN: begin
                if (run_left == 6'd0) st <= S_OP; else run_left <= run_left - 6'd1;
            end
            S_DRAIN: if (blen == 15'd0) st <= (cnt == 16'd0) ? S_END : S_FILL;
            S_FILL: begin
                if (cnt == 16'd0) st <= S_END;
                else begin
                    out_valid <= 1'b1;  out_data <= 24'd0;  out_err <= 1'b1;
                    out_last <= (cnt == 16'd1);  cnt <= cnt - 16'd1;
                end
            end
            S_END: begin line_end <= 1'b1;  line_err <= err;  st <= S_H0; end
            default: st <= S_H0;
            endcase

            if (emit) begin
                out_valid <= 1'b1;  out_err <= 1'b0;  out_last <= (cnt == 16'd1);
                out_data <= f565 ? {8'd0, er[4:0], eg[5:0], eb[4:0]} : {er, eg, eb};
                pr <= er;  pg <= eg;  pb <= eb;
                cnt <= cnt - 16'd1;
            end
        end
    end
endmodule

`default_nettype wire
