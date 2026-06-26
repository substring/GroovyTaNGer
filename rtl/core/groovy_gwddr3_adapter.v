// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - adapter: presents the GOWIN DDR3 Memory Interface IP (native
// cmd/cmd_en/cmd_ready + rd_data_valid/rd_data[127:0]) to groovy_linebuf_reader as
// the SIMPLE single-word interface it already uses (rd/busy/data_ready/dout). This
// lets the proven SINGLE_WORD reader run UNCHANGED on the Gowin IP - no lane-mapping
// or burst-drain risk. The Gowin IP returns 128 bits (8 words) per read; we hand the
// reader the one 16-bit word it addressed (rd_data[addr[2:0]*16 +: 16]) and pulse
// data_ready. Wasteful (read 8, use 1) but the IP has ~10x bandwidth headroom and this
// is the safest route to a working picture; a true 8-word burst is a later optimization.
//
// Also drives WRITES (for the boot pattern writer) through a tiny mux: the writer owns
// the port until fill_done, then the reader does. Native write = cmd=0 + wr_data[127:0]
// (we replicate the single 16-bit word across the 8-word beat and mask to the target).
`default_nettype none

module groovy_gwddr3_adapter (
    input  wire         uclk,           // IP user clock (clk_out, ~75 MHz)
    input  wire         urst,           // IP user reset (ddr_rst, active high)
    input  wire         init_calib_complete,

    // ---- reader/writer simple side ----
    input  wire         rd,             // read pulse (reader)
    input  wire         wr,             // write pulse (writer)
    input  wire [25:0]  addr,           // 16-bit WORD address
    input  wire [15:0]  din,            // write data (single word)
    output reg          busy,           // 0 = ready for a new rd/wr
    output reg          data_ready,     // read data valid (1 cyc)
    output reg  [15:0]  dout,           // the addressed 16-bit word

    // ---- Gowin DDR3 IP native side ----
    output reg  [2:0]   cmd,            // 0=write 1=read
    output reg          cmd_en,
    input  wire         cmd_ready,
    output reg  [26:0]  ip_addr,        // burst (8-word) aligned: word_addr<<... see below
    output reg  [127:0] wr_data,
    output reg          wr_data_en,
    output reg          wr_data_end,
    output reg  [15:0]  wr_data_mask,
    input  wire         wr_data_rdy,
    input  wire [127:0] rd_data,
    input  wire         rd_data_valid
);
    // The IP address indexes 16-bit words but BL8 consumes 8 words/burst, so the low 3
    // address bits select the word WITHIN the returned 128-bit beat, and the burst
    // address = {word_addr[25:3], 3'b000}. (Matches Sipeed: O_addr[2:0] tied 0, +8/burst.)
    wire [2:0]  word_sel = addr[2:0];
    wire [26:0] burst_addr = {1'b0, addr[25:3], 3'b000};

    // BURST-CACHE READ: one IP read returns 8 words; the reader reads sequentially, so
    // we CACHE the 128-bit beat and serve up to 8 consecutive single-word reads from it
    // with ZERO extra IP traffic (1 real read per 8). A read whose burst address matches
    // the cache returns instantly (1-cyc data_ready); a miss does a real IP read first.
    // This cuts IP transactions 8x -> the fetch keeps up with the line rate.
    localparam A_IDLE=2'd0, A_RD=2'd1, A_RWAIT=2'd2, A_WR=2'd3;
    reg [1:0]   st = A_IDLE;
    reg [2:0]   sel_q;                   // which word of the beat we want
    reg [127:0] cache;                   // last fetched 128-bit beat
    reg [26:0]  cache_addr;              // burst address held in cache
    reg         cache_vld;               // cache holds valid data
    wire        cache_hit = cache_vld && (burst_addr == cache_addr);

    always @(posedge uclk or posedge urst) begin
        if (urst) begin
            st<=A_IDLE; busy<=1'b1; data_ready<=1'b0; dout<=16'd0;
            cmd<=3'd0; cmd_en<=1'b0; ip_addr<=27'd0;
            wr_data<=128'd0; wr_data_en<=1'b0; wr_data_end<=1'b0; wr_data_mask<=16'd0;
            cache<=128'd0; cache_addr<=27'h7FFFFFF; cache_vld<=1'b0;
        end else begin
            cmd_en<=1'b0; wr_data_en<=1'b0; wr_data_end<=1'b0; data_ready<=1'b0;
            case (st)
                A_IDLE: begin
                    busy <= ~init_calib_complete;   // ready only after training
                    if (init_calib_complete) begin
                        if (rd) begin
                            if (cache_hit) begin
                                // serve from cache immediately (no IP read)
                                dout <= cache[word_sel*16 +: 16];
                                data_ready <= 1'b1;   // busy stays 0 -> back-to-back reads
                            end else begin
                                ip_addr<=burst_addr; sel_q<=word_sel; busy<=1'b1; st<=A_RD;
                            end
                        end else if (wr) begin
                            // write the single word into its slot, mask the rest off.
                            ip_addr <= burst_addr;
                            wr_data <= {8{din}};                      // word in every slot
                            wr_data_mask <= ~(16'h3 << (word_sel*2)); // unmask only word_sel's 2 bytes
                            cache_vld<=1'b0;                          // a write invalidates the read cache
                            busy<=1'b1; st<=A_WR;
                        end
                    end
                end
                // READ MISS: issue read cmd (wait cmd_ready), then wait its rd_data_valid.
                A_RD: if (cmd_ready) begin cmd<=3'd1; cmd_en<=1'b1; st<=A_RWAIT; end
                A_RWAIT: if (rd_data_valid) begin
                    cache      <= rd_data;            // fill the cache
                    cache_addr <= ip_addr;
                    cache_vld  <= 1'b1;
                    dout       <= rd_data[sel_q*16 +: 16];
                    data_ready <= 1'b1; busy<=1'b0; st<=A_IDLE;
                end
                // WRITE: issue write cmd + data together (gate on both readies).
                A_WR: if (cmd_ready && wr_data_rdy) begin
                    cmd<=3'd0; cmd_en<=1'b1; wr_data_en<=1'b1; wr_data_end<=1'b1;
                    busy<=1'b0; st<=A_IDLE;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
