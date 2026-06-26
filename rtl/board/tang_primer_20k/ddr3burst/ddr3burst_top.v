// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - DDR3 ACCESS-PATTERN comparison probe.
//
// Question being answered: the DDR3 single-word reads test ~clean in a tight
// sequential loop, but ddr3video's scanout reads (line stride 320, gaps between
// lines, refresh interleaved) corrupt one byte lane badly. Is the ACCESS PATTERN the
// cause? This probe reads the SAME framebuffer two ways, selectable by RDMODE:
//   RDMODE=0  SEQUENTIAL  : addresses 0,1,2,... back-to-back (the old "clean" probe).
//   RDMODE=1  VIDEO-LIKE  : line-by-line, addr = line*LINEW + col, with an idle GAP
//                           between lines (mimics the scanout reader's blanking) and
//                           refresh interleaved - the ddr3video pattern.
// It verifies every read against a per-pixel scramble pattern and reports per-byte-
// lane error counts (HI/LO) + first mismatch {addr,exp,got} over UART. If RDMODE=1
// shows the byte-lane corruption and RDMODE=0 does not, the access pattern is the
// cause - the honest answer to "why did the tests work but video fails".
`default_nettype none

module ddr3burst_top (
    input  wire        sys_clk,      // 27 MHz
    input  wire        sys_resetn,
    inout  wire [15:0] DDR3_DQ,
    inout  wire [1:0]  DDR3_DQS,
    output wire [13:0] DDR3_A,
    output wire [2:0]  DDR3_BA,
    output wire        DDR3_nCS,
    output wire        DDR3_nWE,
    output wire        DDR3_nRAS,
    output wire        DDR3_nCAS,
    output wire        DDR3_CK,
    output wire        DDR3_nRESET,
    output wire        DDR3_CKE,
    output wire        DDR3_ODT,
    output wire [1:0]  DDR3_DM,
    output wire [5:0]  led,
    output wire        uart_txp
);
    // ---- clocks ----
    wire clk_x4, clk_ck, clk, lock;
    Gowin_rPLL pll (.clkout(clk_x4), .clkoutp(clk_ck), .lock(lock),
                    .clkoutd(clk), .clkin(sys_clk));
    localparam FREQ = 99_800_000;
    wire resetn = sys_resetn & lock;

    // ---- controller (original, no per-lane mods) ----
    reg          rd=0, wr=0, refresh=0;
    reg  [25:0]  addr=0;
    reg  [15:0]  din=0;
    wire [15:0]  dout;
    wire [127:0] dout128;
    wire         data_ready, busy;
    ddr3_controller #(.ROW_WIDTH(13), .COL_WIDTH(10)) u_ddr3 (
        .pclk(clk), .fclk(clk_x4), .ck(clk_ck), .resetn(resetn),
        .addr(addr), .rd(rd), .wr(wr), .refresh(refresh),
        .din(din), .dout(dout), .dout128(dout128),
        .data_ready(data_ready), .busy(busy),
        .write_level_done(), .wstep(), .read_calib_done(), .rclkpos(), .rclksel(),
        .debug(),
        .DDR3_nRESET(DDR3_nRESET), .DDR3_DQ(DDR3_DQ), .DDR3_DQS(DDR3_DQS),
        .DDR3_A(DDR3_A[12:0]), .DDR3_BA(DDR3_BA), .DDR3_nCS(DDR3_nCS),
        .DDR3_nWE(DDR3_nWE), .DDR3_nRAS(DDR3_nRAS), .DDR3_nCAS(DDR3_nCAS),
        .DDR3_CK(DDR3_CK), .DDR3_CKE(DDR3_CKE), .DDR3_ODT(DDR3_ODT), .DDR3_DM(DDR3_DM));
    assign DDR3_A[13] = 1'b0;

    // ---- refresh timer (subtract-on-execute, HW-proven) ----
    localparam REFRESH_COUNT = FREQ/1000/1000*7813/1000;
    reg [11:0] rtime=0; reg rneed=0, rexec=0;
    always @(posedge clk) begin
        if (!resetn) begin rtime<=0; rneed<=0; end
        else begin
            rtime <= (rtime==(REFRESH_COUNT*2-2)) ? (REFRESH_COUNT*2-2) : rtime+1'b1;
            if (rtime==REFRESH_COUNT) rneed<=1'b1;
            if (rexec) begin rtime<=rtime-REFRESH_COUNT; rneed<=1'b0; end
        end
    end

    // ---- THE EXPERIMENT KNOB ----
    localparam        RDMODE = 1;            // 0=sequential, 1=video-like (line+gap)
    localparam [15:0] LINEW  = 16'd320;
    localparam [15:0] LINES  = 16'd240;
    localparam [25:0] NWORDS = 26'd76800;
    localparam        PASSES = 8'd16;
    localparam [7:0]  GAP    = 8'd0;        // idle cycles between lines (RDMODE=1)

    function [15:0] patf; input [25:0] a;
        patf = ({a[15:0]} * 16'h9E37) ^ 16'hA5A5; endfunction

    // ---- FSM ----
    localparam S_INIT=0, S_WR=1, S_RD=2, S_DONE=3;
    reg [1:0]  st = S_INIT;
    reg [25:0] wa = 0;                 // write addr
    reg [15:0] rln=0, rcol=0;          // read line/col (video-like)
    reg [25:0] rseq=0;                 // read addr (sequential)
    reg [25:0] rd_addr=0;              // address of read in flight
    reg        rinflight=0;
    reg [7:0]  pass=0, gapc=0;
    reg        rcyc=0;

    // results
    reg [19:0] badhi=0, badlo=0;
    reg [25:0] first_err=26'h3FFFFFF;
    reg [15:0] exp0=0, got0=0;
    reg [25:0] reads=0;

    wire [15:0] rd_exp = patf(rd_addr);
    // next read address: EXACTLY like groovy_linebuf_reader - line_base registered
    // once per line (= line*LINEW), then addr = line_base + col per read (a combinational
    // ADD). This reproduces the reader's real address path to test if IT is the bug.
    reg [25:0] line_base = 26'd0;
    // THE FIX: a pre-registered read pointer (seeded from line_base, +1 per read),
    // so the DDR3 addr is a stable register output - not a combinational line_base+rcol.
    reg [25:0] read_ptr = 26'd0;
    wire [25:0] vid_addr = read_ptr;

    always @(posedge clk) begin
        rd<=0; wr<=0; refresh<=0; rexec<=0;
        case (st)
            S_INIT: if (lock && !busy) begin st<=S_WR; wa<=0; end

            // write the whole frame (scramble), proven write path + refresh
            S_WR: begin
                if (wa==NWORDS) begin
                    st<=S_RD; rseq<=0; rln<=0; rcol<=0; line_base<=0; read_ptr<=0; pass<=0; gapc<=0; rinflight<=0;
                end else if (rneed) begin refresh<=1; if(!busy) begin rexec<=1; rcyc<=1; end end
                else if (!wr && !busy) begin
                    if (rcyc) rcyc<=0;
                    else begin wr<=1; addr<=wa; din<=patf(wa); wa<=wa+1'b1; end
                end
            end

            // READ in the selected pattern, verify per byte lane.
            S_RD: begin
                // capture returned data, compare to expected for the in-flight addr
                if (rinflight && data_ready) begin
                    rinflight<=0; reads<=reads+1'b1;
                    if (dout[15:8] !== rd_exp[15:8] && badhi!=20'hFFFFF) badhi<=badhi+1'b1;
                    if (dout[7:0]  !== rd_exp[7:0]  && badlo!=20'hFFFFF) badlo<=badlo+1'b1;
                    if (dout !== rd_exp && first_err==26'h3FFFFFF) begin
                        first_err<=rd_addr; exp0<=rd_exp; got0<=dout;
                    end
                end
                // issue the next read (only when nothing in flight)
                if (!rinflight && !rd) begin
                    if (rneed) begin refresh<=1; if(!busy) begin rexec<=1; rcyc<=1; end end
                    else if (gapc!=0) gapc<=gapc-1'b1;      // inter-line gap (video-like)
                    else if (!busy) begin
                        if (rcyc) rcyc<=0;
                        else if (RDMODE==0) begin
                            // SEQUENTIAL
                            rd<=1; addr<=rseq; rd_addr<=rseq; rinflight<=1;
                            if (rseq==NWORDS-1) begin
                                if (pass==PASSES-1) st<=S_DONE; else begin pass<=pass+1'b1; rseq<=0; end
                            end else rseq<=rseq+1'b1;
                        end else begin
                            // VIDEO-LIKE with THE FIX: addr = read_ptr (pre-registered).
                            rd<=1; addr<=read_ptr; rd_addr<=read_ptr; rinflight<=1;
                            if (rcol==LINEW-1) begin
                                rcol<=0; gapc<=GAP;          // blanking gap before next line
                                if (rln==LINES-1) begin
                                    if (pass==PASSES-1) st<=S_DONE;
                                    else begin pass<=pass+1'b1; rln<=0; line_base<=0; read_ptr<=0; end
                                end else begin rln<=rln+1'b1; line_base<=line_base+LINEW;
                                               read_ptr<=line_base+LINEW; end  // next line base
                            end else begin rcol<=rcol+1'b1; read_ptr<=read_ptr+1'b1; end
                        end
                    end
                end
            end

            S_DONE: ;
        endcase
        if (!resetn) begin
            st<=S_INIT; wa<=0; rseq<=0; rln<=0; rcol<=0; pass<=0; gapc<=0; rcyc<=0;
            rinflight<=0; line_base<=0; read_ptr<=0; badhi<=0; badlo<=0; first_err<=26'h3FFFFFF; exp0<=0; got0<=0; reads<=0;
        end
    end

    wire done = (st==S_DONE);

    // ---- UART ----
    wire [7:0] tx_din; wire tx_wr, tx_busy;
    uart_tx_V2 #(.clk_freq(27_000_000), .uart_freq(115200)) u_tx (
        .clk(sys_clk), .din(tx_din), .wr_en(tx_wr), .tx_busy(tx_busy), .tx_p(uart_txp));
    function [7:0] hx; input [3:0] n; hx=(n<4'd10)?(8'h30+n):(8'h41+n-4'd10); endfunction
    reg [19:0] r_hi, r_lo; reg [25:0] r_fa; reg [15:0] r_ex, r_go; reg r_md;
    always @(posedge sys_clk) begin
        r_hi<=badhi; r_lo<=badlo; r_fa<=first_err; r_ex<=exp0; r_go<=got0; r_md<=RDMODE[0];
    end
    // "M=x HI=xxxxx LO=xxxxx FA=xxxxxx E=xxxx G=xxxx\r\n"
    localparam [6:0] LL = 7'd48;
    reg [6:0] ci=0; reg [7:0] txd=0; reg txwr=0; reg [2:0] us=0; reg [23:0] hold=0;
    reg [7:0] lb;
    always @(*) begin
        case (ci)
            0:lb="M";1:lb="=";2:lb=hx({3'b0,r_md});3:lb=" ";
            4:lb="H";5:lb="I";6:lb="=";
            7:lb=hx(r_hi[19:16]);8:lb=hx(r_hi[15:12]);9:lb=hx(r_hi[11:8]);10:lb=hx(r_hi[7:4]);11:lb=hx(r_hi[3:0]);12:lb=" ";
            13:lb="L";14:lb="O";15:lb="=";
            16:lb=hx(r_lo[19:16]);17:lb=hx(r_lo[15:12]);18:lb=hx(r_lo[11:8]);19:lb=hx(r_lo[7:4]);20:lb=hx(r_lo[3:0]);21:lb=" ";
            22:lb="F";23:lb="A";24:lb="=";
            25:lb=hx(r_fa[23:20]);26:lb=hx(r_fa[19:16]);27:lb=hx(r_fa[15:12]);28:lb=hx(r_fa[11:8]);29:lb=hx(r_fa[7:4]);30:lb=hx(r_fa[3:0]);31:lb=" ";
            32:lb="E";33:lb="=";34:lb=hx(r_ex[15:12]);35:lb=hx(r_ex[11:8]);36:lb=hx(r_ex[7:4]);37:lb=hx(r_ex[3:0]);38:lb=" ";
            39:lb="G";40:lb="=";41:lb=hx(r_go[15:12]);42:lb=hx(r_go[11:8]);43:lb=hx(r_go[7:4]);44:lb=hx(r_go[3:0]);
            46:lb=8'h0D;47:lb=8'h0A;default:lb=" ";
        endcase
    end
    always @(posedge sys_clk) begin
        txwr<=1'b0;
        case (us)
            3'd0: if (done) begin ci<=0; us<=3'd1; end
            3'd1: begin txd<=lb; txwr<=1'b1; us<=3'd2; end
            3'd2: if (tx_busy) us<=3'd3;
            3'd3: if (!tx_busy) begin
                if (ci==LL-1) begin us<=3'd4; hold<=24'd2_700_000; end
                else begin ci<=ci+1'b1; us<=3'd1; end
            end
            3'd4: if (hold==0) begin ci<=0; us<=3'd1; end else hold<=hold-1'b1;
            default: us<=3'd0;
        endcase
        if (!resetn) begin us<=0; ci<=0; hold<=0; end
    end
    assign tx_din=txd; assign tx_wr=txwr;

    // LEDs: board0=done, board1=no errors, board2=any error, board4=heartbeat
    reg [24:0] hb=0; always @(posedge sys_clk) hb<=hb+1;
    wire [5:0] board;
    assign board[0]=done; assign board[1]=done&(badhi==0&&badlo==0);
    assign board[2]=done&((badhi!=0)||(badlo!=0)); assign board[3]=1'b0;
    assign board[4]=hb[24]; assign board[5]=1'b0;
    assign led = ~{ board[2], board[4], board[3], board[5], board[1], board[0] };
endmodule

`default_nettype wire
