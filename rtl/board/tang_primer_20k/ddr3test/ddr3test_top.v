// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - DDR3 bring-up + memory self-test (DDR3 steps 1-2).
//
// Instantiates the vendored nand2mario DDR3 controller + its rPLL, runs the
// init/calibration, then a single write/read round-trip and a bulk
// write+verify sweep. Result is shown on the Dock's 6 LEDs (active-low) so the
// test needs no UART:
//   led[0] = write_level_done     (calibration: write leveling OK)
//   led[1] = read_calib_done      (calibration: read cal OK)
//   led[2] = init_done            (controller left busy after calibration)
//   led[3] = running              (heartbeat: test FSM is advancing)
//   led[4] = error_bit            (a verify mismatch was seen)
//   led[5] = pass                 (reached FINISH with no error)
//
// Expected good result: led[5:0] = 6'b101111 lit (pass + init + both cals,
// running may be settled off at FINISH, error off). A failed calibration
// leaves led[0]/led[1] dark; a memory fault lights led[4] and clears led[5].
//
// The FSM mirrors the upstream test top (src/ddr3_top.v) but is rewritten to
// our board pins and LED-only reporting. Controller/PLL are vendored verbatim
// (rtl/vendor/nand2mario_ddr3/, Apache-2.0).
`default_nettype none

module ddr3test_top (
    input  wire        sys_clk,      // 27 MHz
    input  wire        sys_resetn,   // active-low reset (Dock button / SSPI pin)

    // DDR3 (board-fixed pins, see .cst)
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

    output wire [5:0]  led
);
    // ---- clocks: 27 MHz -> 398.25 MHz fclk, 90deg ck, ~99.56 MHz pclk ----
    wire clk_x4, clk_ck, clk, lock;
    Gowin_rPLL pll (
        .clkout (clk_x4),   // 398.25 MHz
        .clkoutp(clk_ck),   // 90-degree shifted memory clock
        .lock   (lock),
        .clkoutd(clk),      // ~99.56 MHz user clock (pclk)
        .clkin  (sys_clk)   // 27 MHz
    );

    localparam FREQ = 99_800_000;

    // ---- controller user port (power-on initialized; see FSM note) ----
    reg         rd = 1'b0, wr = 1'b0, refresh = 1'b0;
    reg  [25:0] addr = 26'd0;
    reg  [15:0] din = 16'd0;
    wire [15:0] dout;
    wire [127:0] dout128;
    wire        data_ready, busy;
    wire        write_level_done, read_calib_done;
    wire [7:0]  wstep;
    wire [63:0] debug;

    ddr3_controller #(.ROW_WIDTH(13), .COL_WIDTH(10)) u_ddr3 (
        .pclk(clk), .fclk(clk_x4), .ck(clk_ck), .resetn(sys_resetn & lock),
        .addr(addr), .rd(rd), .wr(wr), .refresh(refresh),
        .din(din), .dout(dout), .dout128(dout128),
        .data_ready(data_ready), .busy(busy),
        .write_level_done(write_level_done), .wstep(wstep),
        .read_calib_done(read_calib_done), .rclkpos(), .rclksel(),
        .debug(debug),
        .DDR3_nRESET(DDR3_nRESET),
        .DDR3_DQ(DDR3_DQ), .DDR3_DQS(DDR3_DQS),
        // ROW_WIDTH=13 -> controller drives A[12:0]; A[13] is routed but unused
        // (the board's DDR3 part only needs 13 row-address bits at this density).
        .DDR3_A(DDR3_A[12:0]), .DDR3_BA(DDR3_BA),
        .DDR3_nCS(DDR3_nCS), .DDR3_nWE(DDR3_nWE),
        .DDR3_nRAS(DDR3_nRAS), .DDR3_nCAS(DDR3_nCAS),
        .DDR3_CK(DDR3_CK), .DDR3_CKE(DDR3_CKE),
        .DDR3_ODT(DDR3_ODT), .DDR3_DM(DDR3_DM)
    );

    // ---- test region: sweep 1 MB (16-bit words) ----
    localparam [25:0] START_ADDR = 26'h0;
    localparam [25:0] TOTAL_SIZE = 26'd524288;  // 512K words = 1 MB

    // ---- refresh book-keeping (one auto-refresh every ~7.8us) ----
    localparam REFRESH_COUNT = FREQ/1000/1000*7813/1000; // ~781 cycles @100MHz
    reg [11:0] refresh_time    = 12'd0;
    reg        refresh_needed  = 1'b0, refresh_executed = 1'b0;
    reg        running         = 1'b0;

    always @(posedge clk) begin
        if (running) begin
            refresh_time <= (refresh_time == (REFRESH_COUNT*2-2)) ?
                            (REFRESH_COUNT*2-2) : refresh_time + 1'b1;
            if (refresh_time == REFRESH_COUNT) refresh_needed <= 1'b1;
            if (refresh_executed) begin
                refresh_time   <= refresh_time - REFRESH_COUNT;
                refresh_needed <= 1'b0;
            end
        end
        if (~sys_resetn) begin
            refresh_time <= 0; refresh_needed <= 0;
        end
    end

    // ---- main FSM ----
    localparam INIT=0, SINGLE_W=1, SINGLE_R=2, SINGLE_CHK=3,
               WRITE_BLOCK=4, VERIFY_BLOCK=5, FINISH=6;
    // Power-on initializers: the board reset (T10) is idle-high and may never
    // pulse at startup, so the FSM must come up in a known state on its own
    // (otherwise state/error_bit power up as X and the LEDs read garbage).
    reg [2:0]  state       = INIT;
    reg        error_bit   = 1'b0;
    reg        refresh_cycle = 1'b0;
    reg [25:0] check_addr  = 26'd0;
    reg [25:0] heartbeat   = 26'd0;   // free-running; MSB blinks (~bit25 @99.5MHz ~ 0.7s)

    // data pattern for address A (lower byte verified)
    function [15:0] pat; input [25:0] a;
        pat = a[15:0] ^ {6'b0, a[25:16]} ^ 16'd59;
    endfunction

    // expected lower byte for the current verify address (no bit-select on a call)
    wire [15:0] exp_pat  = pat(check_addr);
    wire [7:0]  exp_byte = exp_pat[7:0];

    always @(posedge clk) begin
        wr <= 1'b0; rd <= 1'b0; refresh <= 1'b0; refresh_executed <= 1'b0;
        heartbeat <= heartbeat + 1'b1;

        case (state)
            // wait for controller init/calibration to finish (busy drops)
            INIT: begin
                running <= 1'b0;
                if (lock && sys_resetn && !busy) begin
                    running <= 1'b1;
                    addr    <= 26'h0;
                    din     <= 16'h1122;
                    wr      <= 1'b1;
                    state   <= SINGLE_W;
                end
            end
            // issue a 2nd single write, then read back addr 0
            SINGLE_W: if (!wr && !busy) begin
                addr  <= 26'h1; din <= 16'h3344; wr <= 1'b1;
                state <= SINGLE_R;
            end
            SINGLE_R: if (!wr && !busy) begin
                addr <= 26'h0; rd <= 1'b1; state <= SINGLE_CHK;
            end
            SINGLE_CHK: if (data_ready) begin
                if (dout !== 16'h1122) error_bit <= 1'b1;
                addr  <= START_ADDR;
                state <= WRITE_BLOCK;
            end

            // bulk write: pattern over the whole region, interleaving refresh
            WRITE_BLOCK: begin
                if (addr == (START_ADDR + TOTAL_SIZE)) begin
                    addr <= START_ADDR; check_addr <= START_ADDR;
                    state <= VERIFY_BLOCK;
                end else if (refresh_needed) begin
                    refresh <= 1'b1; refresh_executed <= 1'b1; refresh_cycle <= 1'b1;
                end else if (!wr && !refresh && !busy) begin
                    if (refresh_cycle) refresh_cycle <= 1'b0;
                    else begin wr <= 1'b1; din <= pat(addr); addr <= addr + 1'b1; end
                end
            end

            // bulk verify: read back + compare lower byte
            VERIFY_BLOCK: begin
                if (check_addr == (START_ADDR + TOTAL_SIZE)) begin
                    state <= FINISH;
                end else if (data_ready) begin
                    if (dout[7:0] != exp_byte) error_bit <= 1'b1;
                    check_addr <= check_addr + 1'b1;
                end else if (refresh_needed) begin
                    refresh <= 1'b1; refresh_executed <= 1'b1; refresh_cycle <= 1'b1;
                end else if (!rd && !refresh && !busy) begin
                    if (refresh_cycle) refresh_cycle <= 1'b0;
                    else begin rd <= 1'b1; addr <= check_addr; end
                end
            end

            FINISH: running <= 1'b0;
        endcase

        if (~sys_resetn) begin
            state <= INIT; error_bit <= 1'b0; refresh_cycle <= 1'b0; running <= 1'b0;
        end
    end

    // A[13] is routed on the board but unused at this DDR3 density; tie low.
    assign DDR3_A[13] = 1'b0;

    // ---- LED status (active-low) ----
    // DIAGNOSTIC MAPPING (step 1 bring-up): expose raw signals so we can see
    // exactly why the FSM does/doesn't leave INIT. Re-derive the friendly
    // pass/error mapping once the path is understood.
    //   led[0] = clk alive       (heartbeat MSB blinks ~ every few s @99.5MHz)
    //   led[1] = lock            (PLL locked)
    //   led[2] = sys_resetn      (reset deasserted = high)
    //   led[3] = ~busy           (controller ready -> should let INIT exit)
    //   led[4] = test FINISHED   (state == FINISH: the 1MB sweep completed)
    //   led[5] = test PASSED     (FINISH and NO verify mismatch) <- the verdict
    // Expected good result: all of led[1..5] lit, led[0] blinking, with led[5]
    // (pass) lit. If led[4] lit but led[5] dark => the sweep ran but data
    // mismatched on readback (a real memory fault).
    //
    // HW NOTE: led[2] sits on L16, which is in the SAME bank as the DDR3 pins.
    // The DDR3 SSTL15 pins force that bank to 1.5V VCCIO, so the LVCMOS33 LED on
    // L16 can't drive a proper logic-high and reads dark even though sys_resetn
    // is actually high (proven: the FSM reaches FINISH, which is impossible if
    // sys_resetn were low). led[2] is therefore unreliable in any design that
    // also instantiates DDR3 -- including the future merge into full/. The real
    // verdict is led[5] (PASS), which is on its own 3.3V bank and works.
    assign led = ~{ (state == FINISH) & ~error_bit,
                    (state == FINISH),
                    ~busy,
                    sys_resetn,
                    lock,
                    heartbeat[24] };

endmodule

`default_nettype wire
