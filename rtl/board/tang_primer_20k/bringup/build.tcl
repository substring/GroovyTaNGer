# Groovy_Tang - Phase 1 LED blink, Gowin command-line build.
# Run from this directory:   gw_sh build.tcl
# Produces a bitstream under ./impl/pnr/  (a .fs file).
#
# [VERIFY] Device part string for your exact Tang Primer 20K core board.
# GW2A-LV18PG256C8/I7 is the part named in groovy_tang_spec.md section 2.
set_device -name GW2A-18C GW2A-LV18PG256C8/I7

add_file led_blink.v
add_file led_blink.cst

set_option -top_module led_blink

# synthesize + place&route + generate bitstream
run all
