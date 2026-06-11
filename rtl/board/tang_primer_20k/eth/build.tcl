# Groovy_Tang - Ethernet Milestone A (RX -> parser/session -> LEDs).
# Run from the REPO ROOT:   gw_sh rtl/board/tang_primer_20k/eth/build.tcl
# Produces impl/pnr/*.fs.  [VERIFY] device string for your board.
set_device -name GW2A-18C GW2A-LV18PG256C8/I7

# vendored Sipeed/ZiyangYE RMII+UDP stack (Apache-2.0, see NOTICE.md)
add_file rtl/vendor/sipeed_udp/rmii.svh
add_file rtl/vendor/sipeed_udp/PLL_6M.v
add_file rtl/vendor/sipeed_udp/udp.sv
# our logic
add_file rtl/core/groovy_packet_parser.v
add_file rtl/core/groovy_session.v
add_file rtl/core/groovy_ack_policy.v
add_file rtl/core/groovy_ack_sender.v
add_file rtl/core/groovy_features.v
add_file rtl/core/groovy_tx_arbiter.v
add_file rtl/board/tang_primer_20k/eth/groovy_eth_top.sv
# constraints
add_file rtl/board/tang_primer_20k/eth/groovy_eth.cst
add_file rtl/board/tang_primer_20k/eth/groovy_eth.sdc

set_option -top_module groovy_eth_top
set_option -verilog_std sysv2017     # udp.sv / our top are SystemVerilog
run all
