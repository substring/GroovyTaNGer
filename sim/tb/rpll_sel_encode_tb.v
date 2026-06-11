// SPDX-License-Identifier: GPL-2.0-or-later
// Self-checking tb for rtl/vendor/gowin/rpll_sel_encode.v
`timescale 1ns/1ps
module rpll_sel_encode_tb;
    reg  [6:0] idiv, fbdiv;
    reg  [7:0] odiv;
    wire [5:0] idsel, fbdsel, odsel;
    integer    errors = 0;

    rpll_sel_encode dut (.idiv(idiv), .fbdiv(fbdiv), .odiv(odiv),
                         .idsel(idsel), .fbdsel(fbdsel), .odsel(odsel));

    task chk; input [6:0] id, fb; input [7:0] od;
             input [5:0] eid, efb, eod; input [127:0] name;
    begin
        idiv=id; fbdiv=fb; odiv=od; #1;
        if (idsel!==eid || fbdsel!==efb || odsel!==eod) begin
            $display("FAIL: %0s idiv=%0d fbdiv=%0d odiv=%0d -> %b/%b/%b exp %b/%b/%b",
                     name, id, fb, od, idsel, fbdsel, odsel, eid, efb, eod);
            errors = errors + 1;
        end
    end endtask

    initial begin
        // KEY cross-check: 720p coeffs must match the example's static SEL values
        // (IDIV_SEL=3 -> IDSEL=60, FBDIV_SEL=54 -> FBDSEL=9, ODIV_SEL=2 -> ODSEL=63)
        chk(7'd4, 7'd55, 8'd2,  6'd60, 6'd9,  6'd63, "720p");
        // 15 kHz mode (idiv1 fbdiv5 odiv4)
        chk(7'd1, 7'd5,  8'd4,  6'd63, 6'd59, 6'd62, "15kHz");
        // 480p (idiv3 fbdiv14 odiv4)
        chk(7'd3, 7'd14, 8'd4,  6'd61, 6'd50, 6'd62, "480p");
        // extremes
        chk(7'd1,  7'd1,  8'd2,   6'd63, 6'd63, 6'd63, "min div");
        chk(7'd64, 7'd64, 8'd128, 6'd0,  6'd0,  6'd0,  "max div");
        // each ODIV value
        chk(7'd2,7'd2,8'd8,   6'd62,6'd62,6'b111100, "odiv8");
        chk(7'd2,7'd2,8'd16,  6'd62,6'd62,6'b111000, "odiv16");
        chk(7'd2,7'd2,8'd32,  6'd62,6'd62,6'b110000, "odiv32");
        chk(7'd2,7'd2,8'd48,  6'd62,6'd62,6'b101000, "odiv48");
        chk(7'd2,7'd2,8'd64,  6'd62,6'd62,6'b100000, "odiv64");
        chk(7'd2,7'd2,8'd80,  6'd62,6'd62,6'b011000, "odiv80");
        chk(7'd2,7'd2,8'd96,  6'd62,6'd62,6'b010000, "odiv96");
        chk(7'd2,7'd2,8'd112, 6'd62,6'd62,6'b001000, "odiv112");

        if (errors == 0) $display("PASS: rpll_sel_encode_tb");
        else begin $display("FAIL: rpll_sel_encode_tb (%0d errors)", errors); $fatal(1); end
        $finish;
    end
endmodule
