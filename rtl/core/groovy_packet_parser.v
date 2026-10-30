// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - Groovy_MiSTer UDP command parser (spec section 5.2, Phase 6).
//
// Replaces the HPS-side parsing of groovy.cpp. Consumes a byte stream for ONE
// control packet at a time, delimited by in_sop/in_eop, and emits the decoded
// fields. Strict protocol compatibility: layouts and little-endian field order
// match Groovy_MiSTer exactly (spec section 4 "clone fonctionnel").
//
// NOT handled here (by design): the header-less pixel / audio byte streams that
// follow CMD_AUDIO and CMD_BLIT_*. The top-level routes those raw bytes to the
// VRAM / audio FIFO while `isBlitting` (spec section 5.3); they never reach this
// parser. This module only sees control packets.
//
// Blit length disambiguation (spec section 5.2) is done purely from packet
// length, exactly as the UDP datagram length tells the real receiver:
//   8  bytes : raw blit, no flag
//   9  bytes : raw blit + frame_dup flag
//   12 bytes : lz4 blit, no flag
//   13 bytes : lz4 blit + frame_delta flag
//
// CMD_BLIT_VSYNC (6) is NOT dead: it is the only blit GroovyMAME sends
// (drawnogpu.cpp, packed struct {6, frame u32, vsync u16, cSize u32}, always 11
// bytes even when raw, cSize = 0). groovy.cpp accepts 7 or 11 bytes, sets field 0
// and reads cSize only when CMD_INIT asked for LZ4. This parser has no session
// state, so it reports lz4 = (cSize != 0): the same for conformant traffic (an LZ4
// frame is never 0 bytes, a raw GroovyMAME blit always carries cSize = 0).
`default_nettype none

module groovy_packet_parser (
    input  wire        clk,
    input  wire        rst,

    // Byte stream for one control packet
    input  wire        in_valid,
    input  wire [7:0]  in_data,
    input  wire        in_sop,    // asserted with the packet's first byte
    input  wire        in_eop,    // asserted with the packet's last byte

    // Decode strobe (one cycle, the cycle after in_eop)
    output reg         cmd_valid,
    output reg  [7:0]  cmd,
    output reg         bad_packet,    // unknown cmd or wrong length

    // Per-command strobes (coincident with cmd_valid)
    output reg         close_valid,
    output reg         init_valid,
    output reg         switchres_valid,
    output reg         audio_valid,
    output reg         get_status_valid,
    output reg         blit_valid,
    output reg         get_version_valid,
    output reg         get_features_valid,    // v2.0.0 extension (CMD_GET_FEATURES)
    output reg         get_switchres_valid,   // v2.0.0 debug (CMD_GET_SWITCHRES_RESULT)
    output reg         beacon_valid,          // Groovy_Tang extension (CMD_SET_BEACON)
    output reg         beacon_en,             // its argument: 1 = send raster beacons

    // CMD_INIT fields
    output reg  [7:0]  init_lz4,
    output reg  [7:0]  init_sound_rate,
    output reg  [7:0]  init_sound_chan,
    output reg  [7:0]  init_rgb_mode,

    // CMD_SWITCHRES fields
    output reg  [63:0] sr_pclk,        // IEEE-754 double, little-endian as received
    output reg  [15:0] sr_h_active,
    output reg  [15:0] sr_h_begin,
    output reg  [15:0] sr_h_end,
    output reg  [15:0] sr_h_total,
    output reg  [15:0] sr_v_active,
    output reg  [15:0] sr_v_begin,
    output reg  [15:0] sr_v_end,
    output reg  [15:0] sr_v_total,
    output reg  [7:0]  sr_interlace,

    // CMD_AUDIO fields
    output reg  [15:0] audio_size,

    // CMD_BLIT_FIELD_VSYNC fields
    output reg  [31:0] blit_frame,
    output reg  [7:0]  blit_field,
    output reg  [15:0] blit_vsync,
    output reg         blit_lz4,        // 1 = payload is LZ4 (cSize valid)
    output reg  [31:0] blit_csize,
    output reg         blit_flag        // frame_dup (raw) or frame_delta (lz4)
);
    localparam CMD_CLOSE            = 8'd1;
    localparam CMD_INIT             = 8'd2;
    localparam CMD_SWITCHRES        = 8'd3;
    localparam CMD_AUDIO            = 8'd4;
    localparam CMD_GET_STATUS       = 8'd5;
    localparam CMD_BLIT_VSYNC       = 8'd6;   // GroovyMAME's blit (see header)
    localparam CMD_BLIT_FIELD_VSYNC = 8'd7;
    localparam CMD_GET_VERSION      = 8'd8;
    localparam CMD_GET_FEATURES     = 8'd9;   // Groovy_Tang v2.0.0 extension
    localparam CMD_GET_SWITCHRES_RESULT = 8'd10;  // v2.0.0 debug: read mode-change math
    localparam CMD_SET_BEACON       = 8'd11;  // Groovy_Tang extension: {cmd, enable}

    // Byte buffer (max control packet = SWITCHRES = 26 bytes)
    reg [7:0] pkt [0:25];
    reg [5:0] wptr;
    reg [5:0] len;
    reg       decode_pending;

    integer i;

    always @(posedge clk) begin
        // default single-cycle strobes
        cmd_valid         <= 1'b0;
        close_valid       <= 1'b0;
        init_valid        <= 1'b0;
        switchres_valid   <= 1'b0;
        audio_valid       <= 1'b0;
        get_status_valid  <= 1'b0;
        blit_valid         <= 1'b0;
        get_version_valid   <= 1'b0;
        get_features_valid  <= 1'b0;
        get_switchres_valid <= 1'b0;
        beacon_valid        <= 1'b0;
        bad_packet          <= 1'b0;

        if (rst) begin
            wptr           <= 6'd0;
            decode_pending <= 1'b0;
        end else begin
            // ---- byte capture ----
            if (in_valid) begin
                if (in_sop) begin
                    pkt[0] <= in_data;
                    wptr   <= 6'd1;
                end else if (wptr <= 6'd25) begin
                    pkt[wptr] <= in_data;
                    wptr      <= wptr + 6'd1;
                end
                if (in_eop) begin
                    len            <= in_sop ? 6'd1 : (wptr + 6'd1);
                    decode_pending <= 1'b1;
                end
            end

            // ---- decode (buffer is settled the cycle after eop) ----
            if (decode_pending) begin
                decode_pending <= 1'b0;
                cmd            <= pkt[0];
                cmd_valid      <= 1'b1;

                case (pkt[0])
                    CMD_CLOSE: begin
                        if (len == 6'd1) close_valid <= 1'b1; else bad_packet <= 1'b1;
                    end
                    CMD_INIT: begin
                        // receiver accepts 4 OR 5 bytes (groovy.cpp:2003);
                        // len==4 omits rgbMode -> defaults to RGB888 (0).
                        if (len == 6'd5 || len == 6'd4) begin
                            init_valid      <= 1'b1;
                            init_lz4        <= pkt[1];
                            init_sound_rate <= pkt[2];
                            init_sound_chan <= pkt[3];
                            init_rgb_mode   <= (len == 6'd5) ? pkt[4] : 8'd0;
                        end else bad_packet <= 1'b1;
                    end
                    CMD_SWITCHRES: begin
                        if (len == 6'd26) begin
                            switchres_valid <= 1'b1;
                            sr_pclk    <= {pkt[8],pkt[7],pkt[6],pkt[5],
                                           pkt[4],pkt[3],pkt[2],pkt[1]};
                            sr_h_active<= {pkt[10],pkt[9]};
                            sr_h_begin <= {pkt[12],pkt[11]};
                            sr_h_end   <= {pkt[14],pkt[13]};
                            sr_h_total <= {pkt[16],pkt[15]};
                            sr_v_active<= {pkt[18],pkt[17]};
                            sr_v_begin <= {pkt[20],pkt[19]};
                            sr_v_end   <= {pkt[22],pkt[21]};
                            sr_v_total <= {pkt[24],pkt[23]};
                            sr_interlace <= pkt[25];
                        end else bad_packet <= 1'b1;
                    end
                    CMD_AUDIO: begin
                        if (len == 6'd3) begin
                            audio_valid <= 1'b1;
                            audio_size  <= {pkt[2],pkt[1]};
                        end else bad_packet <= 1'b1;
                    end
                    CMD_GET_STATUS: begin
                        if (len == 6'd1) get_status_valid <= 1'b1; else bad_packet <= 1'b1;
                    end
                    CMD_BLIT_FIELD_VSYNC: begin
                        if (len == 6'd8 || len == 6'd9 || len == 6'd12 || len == 6'd13) begin
                            blit_valid <= 1'b1;
                            blit_frame <= {pkt[4],pkt[3],pkt[2],pkt[1]};
                            blit_field <= pkt[5];
                            blit_vsync <= {pkt[7],pkt[6]};
                            blit_lz4   <= (len >= 6'd12);
                            blit_csize <= (len >= 6'd12) ?
                                          {pkt[11],pkt[10],pkt[9],pkt[8]} : 32'd0;
                            // optional trailing flag byte
                            blit_flag  <= (len == 6'd9)  ? (pkt[8]  != 8'd0) :
                                          (len == 6'd13) ? (pkt[12] != 8'd0) : 1'b0;
                        end else bad_packet <= 1'b1;
                    end
                    CMD_BLIT_VSYNC: begin
                        if (len == 6'd7 || len == 6'd11) begin
                            blit_valid <= 1'b1;
                            blit_frame <= {pkt[4],pkt[3],pkt[2],pkt[1]};
                            blit_field <= 8'd0;
                            blit_vsync <= {pkt[6],pkt[5]};
                            blit_csize <= (len == 6'd11) ?
                                          {pkt[10],pkt[9],pkt[8],pkt[7]} : 32'd0;
                            blit_lz4   <= (len == 6'd11) &&
                                          ({pkt[10],pkt[9],pkt[8],pkt[7]} != 32'd0);
                            blit_flag  <= 1'b0;
                        end else bad_packet <= 1'b1;
                    end
                    CMD_GET_VERSION: begin
                        if (len == 6'd1) get_version_valid <= 1'b1; else bad_packet <= 1'b1;
                    end
                    CMD_GET_FEATURES: begin  // v2.0.0 extension: 1-byte request
                        if (len == 6'd1) get_features_valid <= 1'b1; else bad_packet <= 1'b1;
                    end
                    CMD_GET_SWITCHRES_RESULT: begin  // v2.0.0 debug: 1-byte request
                        if (len == 6'd1) get_switchres_valid <= 1'b1; else bad_packet <= 1'b1;
                    end
                    CMD_SET_BEACON: begin    // 2 bytes: {11, enable}
                        if (len == 6'd2) begin
                            beacon_valid <= 1'b1;
                            beacon_en    <= (pkt[1] != 8'd0);
                        end else bad_packet <= 1'b1;
                    end
                    default: bad_packet <= 1'b1;
                endcase
            end
        end
    end
endmodule

`default_nettype wire
