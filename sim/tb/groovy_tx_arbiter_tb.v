// SPDX-License-Identifier: GPL-2.0-or-later
// Self-checking tb for groovy_tx_arbiter + the two reply senders, against a
// MOCK udp TX sink (with backpressure). Validates the arbiter logic before
// hardware (the real udp FIFO timing is the only untestable part).
`timescale 1ns/1ps
module groovy_tx_arbiter_tb;
    reg clk = 0;
    always #5 clk = ~clk;

    localparam [31:0] REQ_IP   = 32'h0A00020F;   // 10.0.2.15
    localparam [15:0] REQ_PORT = 16'h1234;
    localparam [15:0] OUR_PORT = 16'd32100;
    localparam [7:0]  COMP = 8'h0B, RGB = 8'h05;

    reg rst, ft_start, ack_start;
    reg [31:0] a_frame; reg [15:0] a_vsync, a_vcount; reg [31:0] a_fframe; reg [7:0] a_status;

    wire ft_valid, ft_last, ft_ready, ft_busy;  wire [7:0] ft_data;
    wire ack_valid, ack_last, ack_ready, ack_busy; wire [7:0] ack_data;
    wire [31:0] tx_ip; wire [15:0] tx_src_port, tx_dst_port;
    wire [7:0] tx_data; wire tx_data_av, tx_req;

    // mock udp sink: req always ready; data ready toggles (backpressure)
    reg tx_data_rdy = 1'b1;
    always @(posedge clk) tx_data_rdy <= ~tx_data_rdy;   // 50% duty
    wire tx_req_rdy = 1'b1;

    groovy_features #(.PROTO_MAJOR(8'd2), .PROTO_MINOR(8'd0), .PROTO_PATCH(8'd0),
                      .COMPRESSION(COMP), .RGB_MODES(RGB)) u_ft (
        .clk(clk), .rst(rst), .start(ft_start),
        .out_valid(ft_valid), .out_data(ft_data), .out_last(ft_last),
        .out_ready(ft_ready), .busy(ft_busy));

    groovy_ack_sender u_ack (
        .clk(clk), .rst(rst), .start(ack_start),
        .frame_echo(a_frame), .vsync_echo(a_vsync),
        .fpga_vga_frame(a_fframe), .fpga_vga_vcount(a_vcount), .status_bits(a_status),
        .out_valid(ack_valid), .out_data(ack_data), .out_last(ack_last),
        .out_ready(ack_ready), .busy(ack_busy));

    groovy_tx_arbiter u_arb (
        .clk(clk), .rst(rst),
        .req_ip(REQ_IP), .req_port(REQ_PORT), .our_port(OUR_PORT), .req_valid(1'b1),
        .ack_valid(ack_valid), .ack_data(ack_data), .ack_last(ack_last), .ack_ready(ack_ready),
        .ft_valid(ft_valid), .ft_data(ft_data), .ft_last(ft_last), .ft_ready(ft_ready),
        .sr_valid(1'b0), .sr_data(8'd0), .sr_last(1'b0), .sr_ready(),
        .bc_valid(1'b0), .bc_data(8'd0), .bc_last(1'b0), .bc_ready(),
        .tx_ip(tx_ip), .tx_src_port(tx_src_port), .tx_dst_port(tx_dst_port),
        .tx_data(tx_data), .tx_data_av(tx_data_av), .tx_req(tx_req),
        .tx_req_rdy(tx_req_rdy), .tx_data_rdy(tx_data_rdy));

    reg [7:0] cap [0:31];
    integer   capn;
    reg       req_seen;
    integer   errors = 0, k;
    always @(posedge clk) begin
        if (tx_data_av) begin cap[capn] = tx_data; capn = capn + 1; end
        if (tx_req) begin
            req_seen = 1'b1;
            if (tx_ip !== REQ_IP || tx_dst_port !== REQ_PORT || tx_src_port !== OUR_PORT) begin
                $display("FAIL: tx addr ip=%h dst=%h src=%h", tx_ip, tx_dst_port, tx_src_port);
                errors = errors + 1;
            end
        end
    end

    reg [7:0] exp [0:15];
    initial begin
        rst=1; ft_start=0; ack_start=0;
        a_frame=32'h11223344; a_vsync=16'hAABB; a_fframe=32'h55667788;
        a_vcount=16'hCCDD; a_status=8'h96;
        @(negedge clk); @(negedge clk); rst=0;

        // ---- FEATURES reply ----
        capn=0; req_seen=0;
        @(negedge clk); ft_start=1; @(negedge clk); ft_start=0;
        wait (req_seen); @(negedge clk);
        exp[0]=8'h47;exp[1]=8'h54;exp[2]=8'h46;exp[3]=8'h31;
        exp[4]=8'd2;exp[5]=8'd0;exp[6]=8'd0;exp[7]=COMP;exp[8]=RGB;
        exp[9]=0;exp[10]=0;exp[11]=0;
        if (capn !== 12) begin $display("FAIL: FEATURES %0d bytes (exp 12)", capn); errors=errors+1; end
        for (k=0;k<12;k=k+1) if (cap[k]!==exp[k]) begin
            $display("FAIL: FEAT byte %0d=%h exp %h",k,cap[k],exp[k]); errors=errors+1; end

        // ---- ACK reply (13 bytes, little-endian) ----
        capn=0; req_seen=0;
        @(negedge clk); ack_start=1; @(negedge clk); ack_start=0;
        wait (req_seen); @(negedge clk);
        exp[0]=8'h44;exp[1]=8'h33;exp[2]=8'h22;exp[3]=8'h11;   // frameEcho
        exp[4]=8'hBB;exp[5]=8'hAA;                             // vCountEcho
        exp[6]=8'h88;exp[7]=8'h77;exp[8]=8'h66;exp[9]=8'h55;   // fpga frame
        exp[10]=8'hDD;exp[11]=8'hCC;                           // fpga vcount
        exp[12]=8'h96;                                          // status
        if (capn !== 13) begin $display("FAIL: ACK %0d bytes (exp 13)", capn); errors=errors+1; end
        for (k=0;k<13;k=k+1) if (cap[k]!==exp[k]) begin
            $display("FAIL: ACK byte %0d=%h exp %h",k,cap[k],exp[k]); errors=errors+1; end

        if (errors==0) $display("PASS: groovy_tx_arbiter_tb");
        else begin $display("FAIL: groovy_tx_arbiter_tb (%0d errors)", errors); $fatal(1); end
        $finish;
    end
endmodule
