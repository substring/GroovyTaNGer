`include "rmii.svh"

module top (
    input  clk,        // 27 MHz, H11
    input  rst,        // active-low button, T10
    rmii   netrmii,
    output phyrst,
    output [5:0] led
);
    logic [23:0] ckdiv;
    always_ff @(posedge clk or negedge rst)
        if (!rst) ckdiv <= 24'd0; else ckdiv <= ckdiv + 24'd1;
    wire heartbeat = ckdiv[23];

logic clk1m;
logic clk6m;
PLL_6M PLL6m(
    .clkout(clk6m),
    .clkoutd(clk1m),
    .clkin(clk)
);

logic clk50m;
logic ready;

logic rx_head_av;
logic[31:0] rx_head;
logic rx_data_av;
logic[7:0] rx_data;
logic rx_head_rdy;

logic [31:0] tx_ip;
logic [15:0] tx_dst_port;
logic tx_req;
logic [7:0] tx_data;
logic tx_data_av;
logic tx_req_rdy;
logic tx_data_rdy;

udp #(
    .ip_adr({8'd192,8'd168,8'd15,8'd14}),
    .mac_adr({8'h06,8'h00,8'hAA,8'hBB,8'h0C,8'hDD}),

    .arp_refresh_interval(50000000*15), // 15 seconds    
    .arp_max_life_time(50000000*30) // 30 seconds
)udp_inst(
    .clk1m(clk1m),
    .rst(rst),

    .clk50m(clk50m),
    .ready(ready),

    .netrmii(netrmii),

    .phyrst(phyrst),

    .rx_head_rdy_i(rx_head_rdy),
    .rx_head_av_o(rx_head_av),
    .rx_head_o(rx_head),
    .rx_data_rdy_i(1'b1),
    .rx_data_av_o(rx_data_av),
    .rx_data_o(rx_data),

    .tx_ip_i(tx_ip),
    .tx_src_port_i(16'd11451),
    .tx_dst_port_i(tx_dst_port),
    .tx_req_i(tx_req),
    .tx_data_i(tx_data),
    .tx_data_av_i(tx_data_av),
    .tx_req_rdy_o(tx_req_rdy),
    .tx_data_rdy_o(tx_data_rdy)
);

always_comb begin
    tx_data <= rx_data;
    tx_data_av <= rx_data_av;
end

logic [2:0] hstate;
always_ff @(posedge clk50m or negedge ready) begin
    if (!ready) begin hstate <= 3'd0; rx_head_rdy <= 1'b0; end
    else begin
        rx_head_rdy <= 1'b0;
        case (hstate)
            0: if (rx_head_av) begin rx_head_rdy <= 1'b1; tx_ip <= rx_head; hstate <= 1; end
            1: begin rx_head_rdy <= 1'b1; hstate <= 2; end
            2: begin rx_head_rdy <= 1'b1; hstate <= 3; end
            3: begin rx_head_rdy <= 1'b1; tx_dst_port <= rx_head[31:16] + 16'd1; hstate <= 4; end
            4: if (!rx_head_av) hstate <= 5;
            5: if (tx_req_rdy && !rx_data_av) begin tx_req <= 1'b1; hstate <= 0; end
            default: hstate <= 0;
        endcase
    end
end

assign led = ~{heartbeat, ready, 1'b0, 1'b0, 1'b0, 1'b0};

endmodule

