#!/usr/bin/env bash
# Groovy_Tang - headless Gowin build (synth + P&R + bitstream) via gw_sh.
# Lets the build run from the terminal so its full log is captured directly
# (no GUI, no copy-paste). Produces impl/pnr/<name>.fs next to the .gprj.
#
# Usage:  tools/gw_build.sh path/to/project.gprj
#
# Env workaround (from the user's working gw_ide launch): preload the system
# libstdc++ + libfreetype and point LD_LIBRARY_PATH at Gowin's own libs, plus
# QT_QPA_PLATFORM=offscreen so gw_sh runs without a display.
set -euo pipefail

GPRJ="${1:?usage: gw_build.sh path/to/project.gprj}"
GPRJ="$(readlink -f "$GPRJ")"

GW_HOME="${GW_HOME:-$HOME/GOWIN_EDA_1.9.12.03}"
GW_SH="$GW_HOME/IDE/bin/gw_sh"

TCL="$(mktemp --suffix=.tcl)"
trap 'rm -f "$TCL"' EXIT
printf 'open_project %s\nrun all\n' "$GPRJ" > "$TCL"

env LD_PRELOAD="/lib/x86_64-linux-gnu/libstdc++.so.6:/lib/x86_64-linux-gnu/libfreetype.so.6" \
    LD_LIBRARY_PATH="$GW_HOME/IDE/lib" \
    QT_QPA_PLATFORM=offscreen \
    "$GW_SH" "$TCL"

FS="$(dirname "$GPRJ")/impl/pnr/$(basename "${GPRJ%.gprj}").fs"
if [[ -f "$FS" ]]; then
    echo "BITSTREAM: $FS"
else
    echo "BUILD FAILED: no .fs produced" >&2
    exit 1
fi
