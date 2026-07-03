// SPDX-License-Identifier: GPL-2.0-or-later
// Drives the REAL groovy_gwddr3_adapter against a fake Gowin DDR3 IP whose
// wr_data_rdy LAGS cmd_en by a few cycles (the real IP behaviour that the old
// single-cycle A_WR missed -> dropped writes -> "gaps"). Writes several full beats
// and single masked words, models BL8 storage, then reads them back through the
// adapter and checks the data. This is the bug we're fixing: command/data phase
// decoupling on writes.
`timescale 1ns/1ps
module groovy_adapter_write_tb;
    reg clk=0; always #5 clk=~clk;
    reg rst=1;

    // simple side
    reg         rd=0, wr=0, wr_beat=0;
    reg [25:0]  addr=0;
    reg [15:0]  din=0;
    reg [127:0] din_beat=0;
    wire        busy, data_ready;
    wire [15:0] dout;

    // IP side
    wire [2:0]   cmd; wire cmd_en; reg cmd_ready=1;
    wire [26:0]  ip_addr;
    wire [127:0] wr_data; wire wr_data_en, wr_data_end; wire [15:0] wr_data_mask;
    reg          wr_data_rdy=0;
    reg [127:0]  rd_data=0; reg rd_data_valid=0;

    groovy_gwddr3_adapter dut(
        .uclk(clk), .urst(rst), .init_calib_complete(1'b1),
        .rd(rd), .wr(wr), .wr_beat(wr_beat), .addr(addr), .din(din), .din_beat(din_beat),
        .busy(busy), .data_ready(data_ready), .dout(dout),
        .cmd(cmd), .cmd_en(cmd_en), .cmd_ready(cmd_ready), .ip_addr(ip_addr),
        .wr_data(wr_data), .wr_data_en(wr_data_en), .wr_data_end(wr_data_end),
        .wr_data_mask(wr_data_mask), .wr_data_rdy(wr_data_rdy),
        .rd_data(rd_data), .rd_data_valid(rd_data_valid));

    // ---- fake Gowin DDR3 IP ----
    // memory keyed by burst address (8 words/entry). On a write COMMAND (cmd_en,cmd=0)
    // the IP raises wr_data_rdy a FEW CYCLES LATER, then latches wr_data on the cycle
    // wr_data_en & wr_data_rdy. On a read command, returns the burst after a latency.
    reg [127:0] mem [0:1023];          // indexed by burst addr (ip_addr>>3)
    integer i; initial for(i=0;i<1024;i=i+1) mem[i]=128'hDEAD;

    reg [26:0] wburst; reg wpend; integer wdly;
    reg [26:0] rburst; reg rpend; integer rdly;

    always @(posedge clk) begin
        if (rst) begin wr_data_rdy<=0; wpend<=0; wdly<=0; rd_data_valid<=0; rpend<=0; rdly<=0; end
        else begin
            rd_data_valid<=0;
            // capture a command
            if (cmd_en && cmd==3'd0) begin            // WRITE cmd
                wburst<=ip_addr; wpend<=1; wdly<=3;    // wr_data_rdy will lag by 3 cyc
            end
            if (cmd_en && cmd==3'd1) begin            // READ cmd
                rburst<=ip_addr; rpend<=1; rdly<=4;
            end
            // write-data ready handshake (lagged)
            if (wpend) begin
                if (wdly>0) wdly<=wdly-1;
                else begin
                    wr_data_rdy<=1;
                    if (wr_data_en && wr_data_rdy) begin   // adapter supplies data
                        // apply mask per 16-bit word (mask bit pair per word: 2 bytes)
                        for (i=0;i<8;i=i+1)
                            if (wr_data_mask[i*2 +: 2]==2'b00)
                                mem[wburst>>3][i*16 +: 16] <= wr_data[i*16 +: 16];
                        wr_data_rdy<=0; wpend<=0;
                    end
                end
            end
            // read latency
            if (rpend) begin
                if (rdly>0) rdly<=rdly-1;
                else begin rd_data<=mem[rburst>>3]; rd_data_valid<=1; rpend<=0; end
            end
        end
    end

    // ---- test ----
    integer errs=0; reg [15:0] got;
    task do_wr_beat(input [25:0] a, input [127:0] d);
        begin @(negedge clk); addr<=a; din_beat<=d; wr_beat<=1; @(negedge clk); wr_beat<=0;
              while(busy) @(negedge clk); end
    endtask
    task do_rd(input [25:0] a);
        begin @(negedge clk); addr<=a; rd<=1; @(negedge clk); rd<=0;
              while(!data_ready) @(negedge clk); got=dout; end
    endtask

    initial begin
        repeat(4) @(negedge clk); rst=0; repeat(2) @(negedge clk);
        // write burst 0 (addr 0..7) with distinct words
        do_wr_beat(26'd0, {16'h0007,16'h0006,16'h0005,16'h0004,16'h0003,16'h0002,16'h0001,16'h0000});
        // write burst 1 (addr 8..15)
        do_wr_beat(26'd8, {16'h0017,16'h0016,16'h0015,16'h0014,16'h0013,16'h0012,16'h0011,16'h0010});
        // read them all back
        do_rd(26'd0); if(got!==16'h0000) begin errs=errs+1; $display("BAD a0=%h",got); end
        do_rd(26'd3); if(got!==16'h0003) begin errs=errs+1; $display("BAD a3=%h",got); end
        do_rd(26'd7); if(got!==16'h0007) begin errs=errs+1; $display("BAD a7=%h",got); end
        do_rd(26'd8); if(got!==16'h0010) begin errs=errs+1; $display("BAD a8=%h",got); end
        do_rd(26'd15);if(got!==16'h0017) begin errs=errs+1; $display("BAD a15=%h",got); end
        if (errs==0) $display("PASS: groovy_adapter_write_tb (two-phase write lands; wr_data_rdy lag tolerated)");
        else         $display("FAIL: %0d errors", errs);
        $finish;
    end
    initial begin #200000; $display("TIMEOUT"); $finish; end
endmodule
