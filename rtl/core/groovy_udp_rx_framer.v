// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - turns the Sipeed udp.sv receive FIFOs back into delimited datagrams.
//
// udp.sv hands out received data through two independent FIFOs: 4 header words per
// datagram (src ip, dst ip, {src port, dst port}, {ip id, payload length}) and a flat
// byte FIFO with every payload concatenated. The byte FIFO alone carries NO packet
// boundary. The board tops used to guess one from a gap in rx_data_av ("it went empty,
// so a datagram ended") - which is only true when datagrams are far apart. A short
// datagram committed while a long one is still being read out simply continues the same
// burst: no gap, no start-of-packet, and the parser never sees it. That is exactly the
// CMD_BLIT header that follows a frame's last pixel datagram ~40 us later (the 1280
// payload bytes take 52 us to leave the FIFO): every frame after the first was lost
// (HW: RD=3 after 60 frames sent; sim: gwline_top_e2e_tb, RD stuck at 1).
//
// This block reads the header FIFO first and then takes EXACTLY `length` payload bytes,
// so boundaries are exact however closely datagrams follow each other. It also replaces
// the old header reader, which parked until the header FIFO ran empty and would hang if
// a second datagram had already been queued.
//
// FIFO handshake (both): a word/byte is transferred on a cycle where av and rdy are both
// high, and it is the value on the data bus during that cycle.
`default_nettype none

module groovy_udp_rx_framer (
    input  wire        clk,
    input  wire        rst,

    input  wire        rx_head_av,
    input  wire [31:0] rx_head,
    output wire        rx_head_rdy,
    input  wire        rx_data_av,
    input  wire [7:0]  rx_data,
    output wire        rx_data_rdy,

    output reg         p_valid,     // one payload byte
    output reg  [7:0]  p_data,
    output reg         p_sop,       // with the datagram's first byte
    output reg         p_eop,       // with the datagram's last byte

    output reg  [31:0] src_ip,      // sender of the most recent datagram (reply address)
    output reg  [15:0] src_port
);
    localparam [1:0] S_HEAD = 2'd0, S_DATA = 2'd1;
    reg [1:0]  state;
    reg [1:0]  hidx;
    reg [15:0] remain;
    reg        first;

    assign rx_head_rdy = (state == S_HEAD);
    assign rx_data_rdy = (state == S_DATA);

    wire take_head = rx_head_av && rx_head_rdy;
    wire take_data = rx_data_av && rx_data_rdy;

    always @(posedge clk) begin
        p_valid <= 1'b0;  p_sop <= 1'b0;  p_eop <= 1'b0;
        if (rst) begin
            state <= S_HEAD;  hidx <= 2'd0;  remain <= 16'd0;  first <= 1'b0;
            src_ip <= 32'd0;  src_port <= 16'd0;
        end else if (take_head) begin
            hidx <= hidx + 2'd1;
            case (hidx)
                2'd0: src_ip   <= rx_head;
                2'd2: src_port <= rx_head[31:16];
                2'd3: begin
                    remain <= rx_head[15:0];
                    first  <= 1'b1;
                    if (rx_head[15:0] != 16'd0) state <= S_DATA;   // empty datagram: no bytes
                end
                default: ;
            endcase
        end else if (take_data) begin
            p_valid <= 1'b1;
            p_data  <= rx_data;
            p_sop   <= first;
            p_eop   <= (remain == 16'd1);
            first   <= 1'b0;
            remain  <= remain - 16'd1;
            if (remain == 16'd1) state <= S_HEAD;
        end
    end
endmodule

`default_nettype wire
