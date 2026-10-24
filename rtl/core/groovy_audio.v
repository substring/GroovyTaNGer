// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - audio path: CMD_AUDIO PCM bytes -> sample buffer -> PT8211 DAC (Dock jack).
//
// RECEIVE (Groovy_MiSTer model, groovy.cpp / groovymister.cpp CMD_AUDIO): a 3-byte header
// {4, soundSize u16 LE} is followed by soundSize raw bytes in the next datagrams: signed
// 16-bit little-endian PCM, channels interleaved L,R when stereo (soundChan from CMD_INIT).
// While `receiving`, the top routes the RX bytes here instead of to the parser (exactly
// like groovy_blit_rx for pixels), with the same idle timeout so a lost datagram cannot
// leave the parser gated off forever.
//
// BUFFER: 2^AW 16-bit words in block RAM (registered read). Host bursts (one per video
// frame, ~800 stereo samples at 48 kHz) are absorbed here. Playback starts once PREROLL
// words are buffered and plays at the exact sample rate; if the buffer runs dry it
// outputs silence, counts an underrun and waits for PREROLL again. A full buffer drops
// the incoming sample (counted).
//
// DAC: PT8211 on the Tang Primer 20K Dock (HP_BCK N15, HP_WS P16, HP_DIN P15, PA_EN R16),
// as in Sipeed's TangPrimer-20K-example PT8211/: 32 BCK per stereo sample, 16 bits per
// channel, MSB first, WS and DIN aligned (no I2S one-bit delay). Channel: WS LOW = RIGHT,
// WS high = left - heard on the board (440 Hz sent left came out right), although the
// Sipeed example's comment says "low = left" (its demo plays the same tone on both).
// Here WS/DIN change on the BCK FALLING edge, so they are stable at the rising edge.
// BCK = 32 * fs comes from a phase accumulator on clk (50 MHz): no PLL and no clock
// crossing; the +-1 clk (20 ns) edge jitter is irrelevant to this DAC.
`default_nettype none

module groovy_audio #(
    parameter integer AW             = 12,       // buffer: 4096 words
    parameter integer PREROLL        = 1600,     // words before playback (re)starts
    parameter integer TIMEOUT_CYCLES = 400_000,  // 8 ms at 50 MHz, as gwline's blit_rx
    parameter         LR_SWAP        = 1'b0,     // 1: first word of a pair -> right
    parameter integer PA_HOLD_CYCLES = 50_000_000 // amplifier stays on 1 s after playback
) (
    input  wire        clk,                 // 50 MHz
    input  wire        rst,
    // configuration (CMD_INIT): rate 0 none / 1 22050 / 2 44100 / 3 48000, chan 1 or 2
    input  wire [1:0]  cfg_rate,
    input  wire [1:0]  cfg_chan,
    // CMD_AUDIO
    input  wire        start,               // pulse: header parsed
    input  wire [15:0] size_bytes,
    input  wire        in_valid,            // payload byte (gated by the top: receiving)
    input  wire [7:0]  in_data,
    output reg         receiving,
    // DAC pins
    output reg         hp_bck,
    output reg         hp_ws,
    output reg         hp_din,
    output wire        pa_en,
    // health
    output wire        playing,
    output reg  [15:0] underruns,           // times the buffer ran dry while playing
    output reg  [15:0] overflows,           // samples dropped because the buffer was full
    output reg  [15:0] rx_timeouts,         // CMD_AUDIO bursts cut short
    output wire [AW:0] level                // words buffered
);
    // ------------------------------------------------------------------ receive
    reg [15:0] remain;
    reg        lo_have;  reg [7:0] lo_byte;
    reg [31:0] idle;
    reg        wr_req;   reg [15:0] wr_word;

    always @(posedge clk) begin
        wr_req <= 1'b0;
        if (rst) begin
            receiving <= 1'b0;  remain <= 16'd0;  lo_have <= 1'b0;  idle <= 32'd0;
            rx_timeouts <= 16'd0;
        end else if (start) begin
            receiving <= (size_bytes != 16'd0);
            remain    <= size_bytes;
            lo_have   <= 1'b0;
            idle      <= 32'd0;
        end else if (receiving) begin
            if (in_valid) begin
                idle <= 32'd0;
                if (!lo_have) begin lo_byte <= in_data; lo_have <= 1'b1; end
                else begin
                    wr_req  <= 1'b1;  wr_word <= {in_data, lo_byte};  lo_have <= 1'b0;
                end
                if (remain == 16'd1) receiving <= 1'b0;
                remain <= remain - 16'd1;
            end else if (idle >= TIMEOUT_CYCLES) begin
                receiving   <= 1'b0;
                rx_timeouts <= rx_timeouts + 16'd1;
            end else idle <= idle + 32'd1;
        end
    end

    // ------------------------------------------------------------------ buffer
    reg [15:0]  mem [0:(1<<AW)-1];
    reg [AW:0]  wptr, rptr;
    wire        full  = (wptr[AW] != rptr[AW]) && (wptr[AW-1:0] == rptr[AW-1:0]);
    wire        empty = (wptr == rptr);
    assign level = wptr - rptr;
    reg         rd_req;                      // pop the head word into rd_word
    reg [15:0]  rd_word;
    always @(posedge clk) begin
        if (rst) begin
            wptr <= {(AW+1){1'b0}};  rptr <= {(AW+1){1'b0}};  overflows <= 16'd0;
        end else begin
            if (wr_req) begin
                if (!full) begin mem[wptr[AW-1:0]] <= wr_word; wptr <= wptr + 1'b1; end
                else overflows <= overflows + 16'd1;
            end
            if (rd_req && !empty) rptr <= rptr + 1'b1;
        end
        rd_word <= mem[rptr[AW-1:0]];            // registered read (block RAM)
    end

    // ------------------------------------------------------------------ DAC timing
    // tick = 2 * BCK = 64 * fs; INC = 64 * fs / 50 MHz * 2^32
    wire [31:0] inc = (cfg_rate == 2'd1) ? 32'd121221120 :   // 22050 Hz
                      (cfg_rate == 2'd2) ? 32'd242442241 :   // 44100 Hz
                      (cfg_rate == 2'd3) ? 32'd263882790 :   // 48000 Hz
                                           32'd0;            // no sound
    reg [31:0] acc;  reg tick;
    always @(posedge clk) begin
        if (rst) begin acc <= 32'd0; tick <= 1'b0; end
        else {tick, acc} <= {1'b0, acc} + {1'b0, inc};
    end

    // Amplifier only while sound is actually played (+ PA_HOLD_CYCLES, so gaps between
    // bursts do not click). Enabled whenever a rate was configured, it amplified the DAC's
    // idle output for the whole session: a loud hiss with no sound playing (HW).
    reg [31:0] pa_hold;
    always @(posedge clk) begin
        if (rst || cfg_rate == 2'd0) pa_hold <= 32'd0;
        else if (play)              pa_hold <= PA_HOLD_CYCLES;
        else if (pa_hold != 32'd0)  pa_hold <= pa_hold - 32'd1;
    end
    assign pa_en = (cfg_rate != 2'd0) && (play || pa_hold != 32'd0);
    wire   mono  = (cfg_chan == 2'd1);
    reg        play;  assign playing = play;
    reg [4:0]  bitn;                         // bit slot 0..31 of the stereo sample
    reg [15:0] nxt_l, nxt_r;                 // prefetched for the next stereo sample
    reg [31:0] frm;                          // {right, left} being shifted out
    reg [2:0]  fetch;                        // prefetch FSM (runs between BCK edges)
    reg        have_next;

    always @(posedge clk) begin
        rd_req <= 1'b0;
        if (rst || cfg_rate == 2'd0) begin
            hp_bck <= 1'b0;  hp_ws <= 1'b0;  hp_din <= 1'b0;  bitn <= 5'd31;  frm <= 32'd0;
            play <= 1'b0;  underruns <= (rst ? 16'd0 : underruns);
            fetch <= 3'd0;  have_next <= 1'b0;  nxt_l <= 16'd0;  nxt_r <= 16'd0;
        end else begin
            // ---- prefetch the next stereo sample from the buffer (well before it is due)
            if (!play && level >= PREROLL) play <= 1'b1;
            case (fetch)
                3'd0: if (!have_next && play) begin
                          if (level >= (mono ? 1 : 2)) begin rd_req <= 1'b1; fetch <= 3'd1; end
                      end
                3'd1: fetch <= 3'd2;                                  // rptr moved, read settles
                3'd2: begin
                          if (mono) begin nxt_l <= rd_word; nxt_r <= rd_word; have_next <= 1'b1; fetch <= 3'd0; end
                          else begin
                              if (LR_SWAP) nxt_r <= rd_word; else nxt_l <= rd_word;
                              rd_req <= 1'b1;  fetch <= 3'd3;
                          end
                      end
                3'd3: fetch <= 3'd4;
                3'd4: begin
                          if (LR_SWAP) nxt_l <= rd_word; else nxt_r <= rd_word;
                          have_next <= 1'b1;  fetch <= 3'd0;
                      end
                default: fetch <= 3'd0;
            endcase
            // ---- BCK and the serial stream: frm = {right, left}, MSB first
            if (tick) begin
                hp_bck <= ~hp_bck;
                if (hp_bck) begin                        // falling edge: present the next bit
                    if (bitn == 5'd31) begin             // a new stereo sample starts
                        if (have_next) begin                 // WS low slot = right channel
                            frm <= {nxt_r, nxt_l};  hp_din <= nxt_r[15];  have_next <= 1'b0;
                        end else begin                   // buffer dry: silence
                            frm <= 32'd0;  hp_din <= 1'b0;
                            if (play) begin play <= 1'b0; underruns <= underruns + 16'd1; end
                        end
                        hp_ws <= 1'b0;                   // slots 0..15: right
                        bitn  <= 5'd0;
                    end else begin
                        frm    <= {frm[30:0], 1'b0};
                        hp_din <= frm[30];
                        hp_ws  <= (bitn >= 5'd15);       // slots 16..31: left
                        bitn   <= bitn + 5'd1;
                    end
                end
            end
        end
    end
endmodule

`default_nettype wire
