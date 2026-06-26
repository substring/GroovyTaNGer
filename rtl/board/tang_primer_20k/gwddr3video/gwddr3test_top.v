// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - DDR3 read-fidelity self-test using the GOWIN OFFICIAL DDR3 Memory
// Interface IP (DDR3_Memory_Interface_Top, generated in ddr3_ip/). PURPOSE: prove the
// Gowin IP - with its hardware per-byte-lane read-eye training (init_calib_complete) -
// reads our board's DDR3 cleanly, where nand2mario AND the ZiyangYE slow controller
// both failed the low byte lane (~50%).
//
// Native interface (cmd: 0=write 1=read; 128-bit data = BL8 x 16-bit). We write a
// scramble pattern to NBURST 128-bit words, read them back, and count per-byte-lane
// mismatches across all 8 sub-words of each 128-bit beat (HI=odd byte lane DQ[15:8],
// LO=even byte lane DQ[7:0]). Clean => HI=LO=0 => the Gowin IP beat the skew.
//
// Clocking (from the Sipeed OV5640_HDMI720P_DDR3 reference using this same IP):
//   clk        = 27 MHz board reference (PLL input)
//   memory_clk = ~398 MHz (nand2mario Gowin_rPLL clkout; ~= the 400 MHz MEMORY_CLK config)
//   pll_lock   = rPLL lock
//   clk_out    = ~99.5 MHz USER clock - ALL native-interface logic runs on this.
//   init_calib_complete gates the test (init + read training done).
`default_nettype none

module gwddr3test_top (
    input  wire        sys_clk,      // 27 MHz, H11
    input  wire        sys_resetn,   // active-low, T10

    // DDR3 - proper differential DQS/CK via the Gowin PHY (SSTL15D in .cst)
    inout  wire [15:0] ddr_dq,
    inout  wire [1:0]  ddr_dqs,      // SSTL15D pair (p); _n is the second .cst loc
    inout  wire [1:0]  ddr_dqs_n,
    output wire [12:0] ddr_addr,
    output wire [2:0]  ddr_bank,
    output wire        ddr_cs,
    output wire        ddr_ras,
    output wire        ddr_cas,
    output wire        ddr_we,
    output wire        ddr_clk,
    output wire        ddr_clk_n,
    output wire        ddr_cke,
    output wire        ddr_odt,
    output wire        ddr_reset_n,
    output wire [1:0]  ddr_dm,

    output wire [5:0]  led,
    output wire        uart_txp      // M11 -> FT2232 -> /dev/ttyUSB1 @115200
);
    // ---- clocks: 27 MHz ref -> 302.4 MHz memory_clk via the EXACT Sipeed mem_pll
    // (IDIV4/FBDIV55/ODIV2 = the proven PLL for this IP @ MEMORY_CLK=400/CLK_RATIO 1:4).
    // 398 MHz from the nand2mario rPLL gave IC=0 (no calib); 302.4 is the right value. ----
    wire memory_clk, pll_lock;
    mem_pll u_mempll (.clkout(memory_clk), .lock(pll_lock), .clkoutd3(), .reset(~sys_resetn), .clkin(sys_clk));

    // ---- Gowin DDR3 Memory Interface IP ----
    wire        clk_out, ddr_rst, init_calib_complete, cmd_ready, wr_data_rdy;
    wire [127:0] rd_data; wire rd_data_valid, rd_data_end;
    reg  [2:0]  cmd; reg cmd_en; reg [26:0] addr;
    reg  [127:0] wr_data; reg wr_data_en, wr_data_end;

    DDR3_Memory_Interface_Top u_ddr3 (
        .clk(sys_clk), .memory_clk(memory_clk), .pll_lock(pll_lock), .rst_n(sys_resetn),
        .clk_out(clk_out), .ddr_rst(ddr_rst), .init_calib_complete(init_calib_complete),
        .cmd_ready(cmd_ready), .cmd(cmd), .cmd_en(cmd_en), .addr(addr),
        .wr_data_rdy(wr_data_rdy), .wr_data(wr_data), .wr_data_en(wr_data_en),
        .wr_data_end(wr_data_end), .wr_data_mask(16'd0),
        .rd_data(rd_data), .rd_data_valid(rd_data_valid), .rd_data_end(rd_data_end),
        .sr_req(1'b0), .ref_req(1'b0), .sr_ack(), .ref_ack(), .burst(1'b1),
        .O_ddr_addr(ddr_addr), .O_ddr_ba(ddr_bank), .O_ddr_cs_n(ddr_cs),
        .O_ddr_ras_n(ddr_ras), .O_ddr_cas_n(ddr_cas), .O_ddr_we_n(ddr_we),
        .O_ddr_clk(ddr_clk), .O_ddr_clk_n(ddr_clk_n), .O_ddr_cke(ddr_cke),
        .O_ddr_odt(ddr_odt), .O_ddr_reset_n(ddr_reset_n), .O_ddr_dqm(ddr_dm),
        .IO_ddr_dq(ddr_dq), .IO_ddr_dqs(ddr_dqs), .IO_ddr_dqs_n(ddr_dqs_n)
    );

    wire uclk = clk_out;                 // user clock
    wire urst = ddr_rst;                 // user-domain reset (active high)

    // ---- test pattern: each 128-bit beat = 8 scramble(word_index) sub-words ----
    localparam [26:0] NBURST = 27'd9600;        // 9600 * 8 = 76800 words (= the video FB)
    function [15:0] scramble; input [26:0] a;    // a = sub-word index
        scramble = ({a[15:0]} * 16'h9E37) ^ 16'hA5A5; endfunction
    // expected 128-bit beat for burst index b (sub-words 8*b .. 8*b+7)
    function [127:0] exp_beat; input [26:0] b; integer k; reg [127:0] v;
        begin v=0; for (k=0;k<8;k=k+1) v[k*16 +: 16] = scramble(b*8 + k[26:0]); exp_beat=v; end
    endfunction

    // ---- write-all then read-verify FSM (on uclk) ----
    localparam S_INIT=3'd0, S_WR=3'd1, S_WRD=3'd2, S_RWAIT=3'd3, S_RD=3'd4, S_DONE=3'd5;
    reg [2:0]  st = S_INIT;
    reg [26:0] wcnt=0, rcnt=0;
    reg [19:0] err_hi=0, err_lo=0;
    reg [15:0] first_exp=0, first_got=0; reg [26:0] first_idx=0; reg got_first=0;
    reg        pass=0;

    // SERIALIZED FSM (avoids the read/expected desync of the first attempt): write all,
    // then read STRICTLY ONE AT A TIME - issue a read for burst rcnt, wait for ITS
    // rd_data_valid, check it against exp_beat(rcnt), advance. This guarantees the
    // returned beat always matches the expected index regardless of IP latency.
    localparam S_RDISS=3'd6;
    integer k; reg [19:0] hi_acc, lo_acc; reg [127:0] eb;
    always @(posedge uclk or posedge urst) begin
        if (urst) begin
            st<=S_INIT; wcnt<=0; rcnt<=0; cmd_en<=0; wr_data_en<=0; wr_data_end<=0;
            cmd<=0; addr<=0; err_hi<=0; err_lo<=0; pass<=0; got_first<=0;
        end else begin
            cmd_en<=1'b0; wr_data_en<=1'b0; wr_data_end<=1'b0;
            case (st)
                S_INIT: if (init_calib_complete) begin wcnt<=0; st<=S_WR; end

                // WRITE: issue write cmd with its data; native iface accepts when cmd_ready
                // && wr_data_rdy. addr = burst index << 3 (8 words per BL8 burst).
                S_WR: if (cmd_ready && wr_data_rdy) begin
                    cmd        <= 3'd0;                  // write
                    addr       <= {wcnt[23:0], 3'd0};
                    cmd_en     <= 1'b1;
                    wr_data    <= exp_beat(wcnt);
                    wr_data_en <= 1'b1;
                    wr_data_end<= 1'b1;
                    if (wcnt == NBURST-1) begin rcnt<=0; st<=S_RDISS; end
                    else                       wcnt<=wcnt+1'b1;
                end

                // READ issue: one read command for burst rcnt, then wait for its data.
                S_RDISS: if (cmd_ready) begin
                    cmd    <= 3'd1;                       // read
                    addr   <= {rcnt[23:0], 3'd0};
                    cmd_en <= 1'b1;
                    st     <= S_RD;
                end
                // READ wait+check: the very next rd_data_valid is THIS burst's data.
                S_RD: if (rd_data_valid) begin
                    eb = exp_beat(rcnt);
                    hi_acc = err_hi; lo_acc = err_lo;
                    for (k=0;k<8;k=k+1) begin
                        if (rd_data[k*16+8 +: 8] !== eb[k*16+8 +: 8]) begin
                            if (hi_acc!=20'hFFFFF) hi_acc=hi_acc+1;
                            if (!got_first) begin got_first<=1; first_exp<=eb[k*16 +: 16]; first_got<=rd_data[k*16 +: 16]; first_idx<=rcnt*8+k[26:0]; end
                        end
                        if (rd_data[k*16 +: 8] !== eb[k*16 +: 8]) begin
                            if (lo_acc!=20'hFFFFF) lo_acc=lo_acc+1;
                            if (!got_first) begin got_first<=1; first_exp<=eb[k*16 +: 16]; first_got<=rd_data[k*16 +: 16]; first_idx<=rcnt*8+k[26:0]; end
                        end
                    end
                    err_hi<=hi_acc; err_lo<=lo_acc;
                    if (rcnt == NBURST-1) begin pass <= (hi_acc==0 && lo_acc==0); st<=S_DONE; end
                    else begin rcnt<=rcnt+1'b1; st<=S_RDISS; end
                end
                S_DONE: ;
            endcase
        end
    end

    // ---- UART report (sys_clk domain) ----
    wire [7:0] tx_din; wire tx_wr, tx_busy;
    uart_tx_V2 #(.clk_freq(27_000_000), .uart_freq(115200)) u_tx (
        .clk(sys_clk), .din(tx_din), .wr_en(tx_wr), .tx_busy(tx_busy), .tx_p(uart_txp));
    function [7:0] hx; input [3:0] n; hx = (n<4'd10)?(8'h30+n):(8'h41+n-4'd10); endfunction

    reg [19:0] q_hi,q_lo; reg [15:0] q_fe,q_fg; reg [26:0] q_fi; reg [2:0] q_st; reg q_ic,q_p;
    always @(posedge sys_clk) begin
        q_hi<=err_hi; q_lo<=err_lo; q_fe<=first_exp; q_fg<=first_got; q_fi<=first_idx;
        q_st<=st; q_ic<=init_calib_complete; q_p<=pass;
    end

    localparam [7:0] DBGLEN = 8'd58;
    reg [7:0] di=0, dtx=0, dlb; reg dwr=0; reg [2:0] dst=0; reg [23:0] dhold=0;
    always @(*) begin
        case (di)
            0:dlb="H";1:dlb="I";2:dlb="=";
            3:dlb=hx(q_hi[19:16]);4:dlb=hx(q_hi[15:12]);5:dlb=hx(q_hi[11:8]);6:dlb=hx(q_hi[7:4]);7:dlb=hx(q_hi[3:0]);8:dlb=" ";
            9:dlb="L";10:dlb="O";11:dlb="=";
            12:dlb=hx(q_lo[19:16]);13:dlb=hx(q_lo[15:12]);14:dlb=hx(q_lo[11:8]);15:dlb=hx(q_lo[7:4]);16:dlb=hx(q_lo[3:0]);17:dlb=" ";
            18:dlb="F";19:dlb="I";20:dlb="=";
            21:dlb=hx(q_fi[23:20]);22:dlb=hx(q_fi[19:16]);23:dlb=hx(q_fi[15:12]);24:dlb=hx(q_fi[11:8]);25:dlb=hx(q_fi[7:4]);26:dlb=hx(q_fi[3:0]);27:dlb=" ";
            28:dlb="E";29:dlb="=";
            30:dlb=hx(q_fe[15:12]);31:dlb=hx(q_fe[11:8]);32:dlb=hx(q_fe[7:4]);33:dlb=hx(q_fe[3:0]);34:dlb="/";
            35:dlb=hx(q_fg[15:12]);36:dlb=hx(q_fg[11:8]);37:dlb=hx(q_fg[7:4]);38:dlb=hx(q_fg[3:0]);39:dlb=" ";
            40:dlb="I";41:dlb="C";42:dlb="=";43:dlb=hx({3'b0,q_ic});44:dlb=" ";
            45:dlb="S";46:dlb="T";47:dlb="=";48:dlb=hx({1'b0,q_st});49:dlb=" ";
            50:dlb="P";51:dlb="=";52:dlb=hx({3'b0,q_p});
            54:dlb=8'h0D;55:dlb=8'h0A;default:dlb=" ";
        endcase
    end
    always @(posedge sys_clk) begin
        dwr<=1'b0;
        case (dst)
            3'd0: begin di<=0; dst<=3'd1; end
            3'd1: begin dtx<=dlb; dwr<=1'b1; dst<=3'd2; end
            3'd2: if (tx_busy) dst<=3'd3;
            3'd3: if (!tx_busy) begin
                if (di==DBGLEN-1) begin dst<=3'd4; dhold<=24'd2_700_000; end
                else begin di<=di+1'b1; dst<=3'd1; end
            end
            3'd4: if (dhold==0) dst<=3'd0; else dhold<=dhold-1'b1;
        endcase
    end
    assign tx_din=dtx; assign tx_wr=dwr;

    // ---- LEDs (active-low; same scramble map as ddr3video) ----
    reg [24:0] hb=0; always @(posedge sys_clk) hb<=hb+1'b1;
    wire [5:0] board;
    assign board[0] = pll_lock;
    assign board[1] = init_calib_complete;
    assign board[2] = (st==S_DONE);
    assign board[3] = 1'b0;
    assign board[4] = pass;
    assign board[5] = hb[24];
    assign led = ~{ board[0], board[2], board[4], board[3], board[5], board[1] };
endmodule

`default_nettype wire
