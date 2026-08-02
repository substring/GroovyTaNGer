// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - LZ4 block decoder (generic). Roadmap: Phase 8. Spec sections 4, 6.3.
//
// Byte-streaming port of Psakhis's Groovy_MiSTer rtl/lz4.v (extern/Groovy_MiSTer/rtl/lz4.v),
// keeping only its 8-bit-per-cycle path (MiSTer's optional 64-bit/DDR-burst fast path is
// dropped entirely - our input is a UDP byte stream, not a DDR burst, so there is nothing
// for it to speed up here). Must decode EXACTLY what GroovyMAME's `mister_compression lz4`
// emits: LZ4 block format, a sequence of tokens
//   [token byte: high nibble = literal run length, low nibble = match length]
//   [literal-length extra bytes, only if high nibble == 15: each 0xFF continues, else stop]
//   [literal bytes x literal run length]
//   [offset, 2 bytes little-endian: distance back into the decoded window]
//   [match-length extra bytes, only if low nibble == 15: each 0xFF continues, else stop]
//   ... repeat until c_size compressed bytes consumed.
// Per the LZ4 block spec, the LAST token in a block is literals-only (no offset/match
// field) - the encoder simply stops emitting after the final literal run. We detect this
// the same way MiSTer's reference does: `blocks_readed` (rd_total >= c_size) is checked at
// every point the FSM would otherwise wait for more input; if the compressed stream is
// already exhausted, we skip straight to S_DONE instead of blocking forever on a byte that
// will never arrive.
//
// Input: compressed byte stream (c_size bytes from CMD_BLIT lz4 variant, i.e. blit_csize).
// Output: decompressed pixel byte stream, one byte per cycle it is valid.
`default_nettype none

module lz4_decoder #(
    parameter WINDOW_LOG = 13   // 8 KB window (matches MiSTer's WINDOW_SIZE=8192)
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] c_size,        // compressed size (from blit_csize)
    input  wire        in_valid,
    input  wire [7:0]  in_data,
    output wire        in_ready,      // 1 = accept in_data this cycle
    output wire        out_valid,
    output wire [7:0]  out_data,
    output wire        done           // 1-cycle pulse: fully decoded, back to idle
);
    localparam integer WINDOW_SIZE = (1 << WINDOW_LOG);

    localparam [3:0]
        S_IDLE                 = 4'd0,
        S_READ_TOKEN           = 4'd1,
        S_READ_LITLEN_EXT      = 4'd2,
        S_READ_LITERALS        = 4'd3,
        S_READ_OFFSET_LO       = 4'd4,
        S_READ_OFFSET_HI       = 4'd5,
        S_READ_MATCHLEN_EXT    = 4'd6,
        S_COPY_MATCH           = 4'd7,
        S_DONE                 = 4'd8;

    reg [3:0]  state;
    reg [31:0] rd_total;      // compressed bytes consumed so far (vs c_size)
    reg [31:0] LL, ML;        // remaining literal / match length
    reg [15:0] offset;        // match offset, little-endian on the wire
    reg [WINDOW_LOG-1:0] wr_ptr;   // next write position in the decode window
    reg [15:0] mp_full;            // window_addr - offset, full 16-bit (matches MiSTer's MP)
    wire [WINDOW_LOG-1:0] mp = mp_full[WINDOW_LOG-1:0];  // truncated to the window's own size

    reg [7:0]  window [0:WINDOW_SIZE-1];

    reg        out_valid_r;
    reg [7:0]  out_data_r;
    reg        done_r;

    wire blocks_readed = (rd_total >= c_size);

    // Accept a new compressed byte only in states that consume one this cycle, and only
    // while the block still has unread compressed bytes.
    wire byte_consuming = (state == S_READ_TOKEN) || (state == S_READ_LITLEN_EXT) ||
                          (state == S_READ_LITERALS) || (state == S_READ_OFFSET_LO) ||
                          (state == S_READ_OFFSET_HI) || (state == S_READ_MATCHLEN_EXT);
    assign in_ready = byte_consuming && !blocks_readed;

    wire [7:0] wdata = in_data;
    wire       take  = in_valid && in_ready;   // a real compressed byte is consumed this cycle

    always @(posedge clk) begin
        out_valid_r <= 1'b0;
        done_r      <= 1'b0;

        if (rst) begin
            state    <= S_IDLE;
            rd_total <= 32'd0;
            LL       <= 32'd0;
            ML       <= 32'd0;
            offset   <= 16'd0;
            wr_ptr   <= {WINDOW_LOG{1'b0}};
        end else begin
            case (state)
                S_IDLE: begin
                    rd_total <= 32'd0;
                    LL       <= 32'd0;
                    ML       <= 32'd0;
                    wr_ptr   <= {WINDOW_LOG{1'b0}};
                    if (c_size != 32'd0)
                        state <= S_READ_TOKEN;
                end

                S_READ_TOKEN: begin
                    if (take) begin
                        rd_total <= rd_total + 32'd1;
                        LL       <= {28'd0, wdata[7:4]};
                        ML       <= {28'd0, wdata[3:0]};
                        if (wdata[7:4] == 4'hF)
                            state <= S_READ_LITLEN_EXT;
                        else if (wdata[7:4] != 4'd0)
                            state <= S_READ_LITERALS;
                        else
                            state <= S_READ_OFFSET_LO;
                    end else if (blocks_readed) begin
                        state <= S_DONE;
                    end
                end

                S_READ_LITLEN_EXT: begin
                    if (take) begin
                        rd_total <= rd_total + 32'd1;
                        LL       <= LL + {24'd0, wdata};
                        if (wdata != 8'hFF)
                            state <= S_READ_LITERALS;
                    end else if (blocks_readed) begin
                        state <= S_DONE;
                    end
                end

                S_READ_LITERALS: begin
                    if (LL == 32'd0) begin
                        state <= S_READ_OFFSET_LO;
                    end else if (take) begin
                        rd_total       <= rd_total + 32'd1;
                        window[wr_ptr] <= wdata;
                        wr_ptr         <= wr_ptr + 1'b1;
                        out_data_r     <= wdata;
                        out_valid_r    <= 1'b1;
                        LL             <= LL - 32'd1;
                        if (LL == 32'd1)
                            state <= S_READ_OFFSET_LO;
                    end else if (blocks_readed) begin
                        state <= S_DONE;
                    end
                end

                S_READ_OFFSET_LO: begin
                    if (blocks_readed) begin
                        state <= S_DONE;          // last token: literals-only, no offset field
                    end else if (take) begin
                        rd_total    <= rd_total + 32'd1;
                        offset[7:0] <= wdata;
                        state       <= S_READ_OFFSET_HI;
                    end
                end

                S_READ_OFFSET_HI: begin
                    if (take) begin
                        rd_total     <= rd_total + 32'd1;
                        offset[15:8] <= wdata;
                        mp_full      <= {{(16-WINDOW_LOG){1'b0}}, wr_ptr} - {wdata, offset[7:0]};
                        if (ML == 4'hF)
                            state <= S_READ_MATCHLEN_EXT;
                        else begin
                            ML    <= ML + 32'd4;
                            state <= S_COPY_MATCH;
                        end
                    end
                end

                S_READ_MATCHLEN_EXT: begin
                    if (take) begin
                        rd_total <= rd_total + 32'd1;
                        if (wdata == 8'hFF) begin
                            ML <= ML + 32'd255;
                        end else begin
                            ML    <= ML + {24'd0, wdata} + 32'd4;
                            state <= S_COPY_MATCH;
                        end
                    end
                end

                S_COPY_MATCH: begin
                    // pure window playback: no new compressed byte consumed this cycle
                    window[wr_ptr] <= window[mp];
                    out_data_r     <= window[mp];
                    out_valid_r    <= 1'b1;
                    wr_ptr         <= wr_ptr + 1'b1;
                    mp_full        <= mp_full + 16'd1;
                    ML             <= ML - 32'd1;
                    if (ML == 32'd1)
                        state <= S_READ_TOKEN;
                end

                S_DONE: begin
                    done_r <= 1'b1;
                    state  <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    assign out_valid = out_valid_r;
    assign out_data  = out_data_r;
    assign done      = done_r;
endmodule

`default_nettype wire
