# Groovy_Tang - Phase 1 LED blink timing constraints (Gowin SDC).
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Declares the 27 MHz onboard clock so the timing analyzer stops warning
# (TA1132) and can actually evaluate paths. 27 MHz -> period 1000/27 = 37.037 ns.
create_clock -name Clock -period 37.037 [get_ports {Clock}]
