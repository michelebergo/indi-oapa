#!/bin/bash
# PAC contract test for indi_oapa, without hardware.
#
# Starts the fake OAPA firmware on a pseudo-terminal and indiserver with the
# driver, then drives the properties exactly as Ekos and the INDI Control Panel do
# and checks what reaches the wire and which property states come back.
#
# Usage: tests/pac_contract_test.sh [path/to/indi_oapa]
# Needs indiserver, indi_getprop and indi_setprop on PATH (INDI >= 2.2).
#
# Every failure message starts with the same label as the matching pass, so a
# mutation check can look for "FAIL  <label>".

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
DRIVER="${1:-indi_oapa}"
PORT=7625
DEV="OAPA"
LINK="/tmp/ttyOAPA_test"
WORK="$(mktemp -d)"
FIFO="$WORK/indififo"
FAILS=0

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILS=$((FAILS + 1)); }

# -w: PAC_MANUAL_ADJUSTMENT is write-only and is hidden without it.
getprop() { indi_getprop -p $PORT -w -1 -t 2 "$DEV.$1" 2>/dev/null; }
setprop() { indi_setprop -p $PORT "$DEV.$1"; }
state()   { indi_getprop -p $PORT -w -1 -t 2 "$DEV.$1._STATE" 2>/dev/null; }

# Wait up to $2 seconds for property state $1 to equal $3.
wait_state() {
    local deadline=$((SECONDS + $2))
    while [ $SECONDS -lt $deadline ]; do
        [ "$(state "$1")" = "$3" ] && return 0
        sleep 0.2
    done
    return 1
}

# Property states can be left over from the previous step, so moves and settings are
# proven on the wire: wire checks the fake firmware log, wait_wire waits for a line.
# grep -a: truncating the log under a live writer leaves NUL padding.
wire()       { grep -a -q "$1" "$WORK/fake.log"; }
wire_lines() { grep -a "$1" "$WORK/fake.log" | tr '\n' ' '; }
wait_wire() {
    local deadline=$((SECONDS + $2))
    while [ $SECONDS -lt $deadline ]; do
        wire "$1" && return 0
        sleep 0.2
    done
    return 1
}
clear_wire() { : > "$WORK/fake.log"; }

FAKE_PID=""
start_fake() {
    [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null && wait "$FAKE_PID" 2>/dev/null
    python3 "$HERE/fake_oapa_firmware.py" --link "$LINK" "$@" > "$WORK/fake.log" 2>&1 &
    FAKE_PID=$!
    for _ in $(seq 50); do grep -q READY "$WORK/fake.log" && return 0; sleep 0.1; done
    echo "fake firmware did not start"; cat "$WORK/fake.log"; exit 2
}

connect() {
    setprop "DEVICE_PORT.PORT=$LINK"
    setprop "CONNECTION.CONNECT=On"
    wait_state CONNECTION 15 Ok
}

disconnect() {
    setprop "CONNECTION.DISCONNECT=On"
    wait_state CONNECTION 5 Idle
}

cleanup() {
    [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null
    [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null
    wait 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# Isolate the driver config so a developer's saved settings cannot leak in.
export INDICONFIG="$WORK/config"
export HOME="$WORK"

start_fake
mkfifo "$FIFO"
indiserver -p $PORT -f "$FIFO" > "$WORK/server.log" 2>&1 &
SERVER_PID=$!
sleep 1
echo "start $DRIVER" > "$FIFO"
for _ in $(seq 50); do getprop "CONNECTION.CONNECT" >/dev/null && break; sleep 0.1; done

# 1. Connect: handshake survives the boot banner, firmware version is read.
connect && pass "connect through boot banner" || fail "connect through boot banner"
[ "$(getprop FIRMWARE_INFO.VERSION)" = "1.2.2" ] \
    && pass "firmware version read" || fail "firmware version read: $(getprop FIRMWARE_INFO.VERSION)"
for p in PAC_MANUAL_ADJUSTMENT PAC_ABORT_MOTION PAC_POSITION PAC_AZ_REVERSE OAPA_STEPS_PER_ARCMIN \
         OAPA_SPEED OAPA_MOTOR_CURRENT OAPA_MOTOR_HOLD; do
    getprop "$p.*" >/dev/null && pass "property $p defined" || fail "property $p defined"
done

# 2. Driver currents go out on every connection (the controller forgets them at power-off),
#    type-first. The axis-first form (XC600) is acknowledged by the firmware and ignored.
if wait_wire 'CMD HY25' 5 && wire 'CMD CX600' && wire 'CMD HX25' && wire 'CMD CY600'; then
    pass "connect pushes run/hold current"
else
    fail "connect pushes run/hold current: $(wire_lines 'CMD [CHXY][CHXY][0-9]')"
fi
wire 'CMD [XY][CH][0-9]' \
    && fail "no axis-first driver command: $(wire_lines 'CMD [XY][CH][0-9]')" || pass "no axis-first driver command"

# 3. Changing a motor setting sends it at once, for both axes.
clear_wire
setprop "OAPA_MOTOR_CURRENT.X_CURRENT=800;Y_CURRENT=700"
if wait_wire 'CMD CY700' 3 && wire 'CMD CX800'; then
    pass "run current change sent"
else
    fail "run current change sent: $(wire_lines 'CMD [CH][XY]')"
fi
setprop "OAPA_MOTOR_HOLD.X_HOLD=40;Y_HOLD=35"
if wait_wire 'CMD HY35' 3 && wire 'CMD HX40'; then
    pass "hold current change sent"
else
    fail "hold current change sent: $(wire_lines 'CMD [CH][XY]')"
fi
sleep 0.5
[ "$(state OAPA_MOTOR_HOLD)" = "Ok" ] && pass "motor settings Ok" || fail "motor settings Ok: $(state OAPA_MOTOR_HOLD)"

# 4. Uncalibrated: a correction must be refused, never guessed.
clear_wire
setprop "PAC_MANUAL_ADJUSTMENT.MANUAL_AZ_STEP=0.1;MANUAL_ALT_STEP=0"
wait_state PAC_MANUAL_ADJUSTMENT 3 Alert \
    && pass "uncalibrated move refused" || fail "uncalibrated move refused: $(state PAC_MANUAL_ADJUSTMENT)"
sleep 1
wire 'CMD \$J' && fail "uncalibrated move never sent: $(wire_lines 'CMD \$J')" || pass "uncalibrated move never sent"

# 5. Same speed on both axes: one jog line for both. +0.1 deg AZ at 100 steps/arcmin =
#    +600 steps on X, -0.05 deg ALT at 200 steps/arcmin = -600 steps on Y.
setprop "OAPA_STEPS_PER_ARCMIN.STEPS_AZ=100;STEPS_ALT=200"
setprop "OAPA_SPEED.X_SPEED=3000;Y_SPEED=3000"
sleep 0.5
clear_wire
setprop "PAC_MANUAL_ADJUSTMENT.MANUAL_AZ_STEP=0.1;MANUAL_ALT_STEP=-0.05"
wait_state PAC_MANUAL_ADJUSTMENT 2 Busy && pass "move reports Busy" || fail "move reports Busy: $(state PAC_MANUAL_ADJUSTMENT)"
wait_wire 'CMD \$J' 3
wire 'CMD \$J=G91G21X600Y-600F3000' \
    && pass "one jog line X600 Y-600 F3000" || fail "one jog line X600 Y-600 F3000: $(wire_lines 'CMD \$J')"
wait_wire 'POS 600 -600' 10 && pass "platform at target" || fail "platform at target"
wait_state PAC_MANUAL_ADJUSTMENT 5 Ok && pass "move completes Ok" || fail "move completes Ok: $(state PAC_MANUAL_ADJUSTMENT)"
AZ=$(getprop PAC_POSITION.POSITION_AZ)
awk -v v="$AZ" 'BEGIN{exit !(v > 0.099 && v < 0.101)}' \
    && pass "position reads +0.1 deg" || fail "position reads +0.1 deg: $AZ"

# 6. Different speeds per axis: one jog per axis, each with its own feed.
#    +0.1 deg AZ = +600 steps at 3000; +0.05 deg ALT = +600 steps at 1500.
setprop "OAPA_SPEED.X_SPEED=3000;Y_SPEED=1500"
sleep 0.5
clear_wire
setprop "PAC_MANUAL_ADJUSTMENT.MANUAL_AZ_STEP=0.1;MANUAL_ALT_STEP=0.05"
wait_wire 'CMD \$J=G91G21Y' 3
if wire 'CMD \$J=G91G21X600F3000' && wire 'CMD \$J=G91G21Y600F1500'; then
    pass "per-axis speed: one jog per axis"
else
    fail "per-axis speed: one jog per axis: $(wire_lines 'CMD \$J')"
fi
wait_wire 'POS 1200 0' 10 && pass "per-axis move reaches target" || fail "per-axis move reaches target"
sleep 2
setprop "OAPA_SPEED.X_SPEED=3000;Y_SPEED=3000"
sleep 0.5

# 7. Reverse: the same request must drive the motor the other way.
setprop "PAC_AZ_REVERSE.INDI_ENABLED=On"
clear_wire
setprop "PAC_MANUAL_ADJUSTMENT.MANUAL_AZ_STEP=0.1;MANUAL_ALT_STEP=0"
wait_wire 'CMD \$J' 3
wire 'CMD \$J=G91G21X-600F3000' \
    && pass "reversed azimuth sends X-600" || fail "reversed azimuth sends X-600: $(wire_lines 'CMD \$J')"
wait_wire 'POS 600 0' 10 && pass "reversed move reaches target" || fail "reversed move reaches target"
sleep 2
setprop "PAC_AZ_REVERSE.INDI_DISABLED=On"

# 8. Whole steps, rounded to nearest like the firmware's lround(). At 100 steps/arcmin
#    0.0001 deg = 0.6 steps -> X1 is sent; 0.00005 deg = 0.3 steps -> nothing to move.
clear_wire
setprop "PAC_MANUAL_ADJUSTMENT.MANUAL_AZ_STEP=0.0001;MANUAL_ALT_STEP=0"
wait_wire 'CMD \$J' 3
wire 'CMD \$J=G91G21X1F3000' && pass "0.6 steps rounds to X1" || fail "0.6 steps rounds to X1: $(wire_lines 'CMD \$J')"
wait_wire 'POS 601 0' 5
sleep 2
clear_wire
setprop "PAC_MANUAL_ADJUSTMENT.MANUAL_AZ_STEP=0.00005;MANUAL_ALT_STEP=0"
sleep 1.5
[ "$(state PAC_MANUAL_ADJUSTMENT)" = "Ok" ] && pass "sub-step move Ok" || fail "sub-step move Ok: $(state PAC_MANUAL_ADJUSTMENT)"
wire 'CMD \$J' && fail "sub-step move never sent: $(wire_lines 'CMD \$J')" || pass "sub-step move never sent"

# 9. Abort mid-move: "!" on the wire, platform stops short, state Idle, and the stopped
#    move must not later turn Ok or Alert.
setprop "OAPA_SPEED.X_SPEED=50;Y_SPEED=50"
sleep 0.5
clear_wire
setprop "PAC_MANUAL_ADJUSTMENT.MANUAL_AZ_STEP=1;MANUAL_ALT_STEP=0"
sleep 1.5
setprop "PAC_ABORT_MOTION.ABORT=On"
wait_state PAC_MANUAL_ADJUSTMENT 3 Idle && pass "abort sets Idle" || fail "abort sets Idle: $(state PAC_MANUAL_ADJUSTMENT)"
wire 'CMD !' && pass "abort sends !" || fail "abort sends !"
sleep 3
[ "$(state PAC_MANUAL_ADJUSTMENT)" = "Idle" ] \
    && pass "aborted move stays Idle" || fail "aborted move stays Idle: $(state PAC_MANUAL_ADJUSTMENT)"
setprop "OAPA_SPEED.X_SPEED=3000;Y_SPEED=3000"
disconnect

# 10. Stall: firmware says Run but position never changes -> Alert and "!".
start_fake --stall
connect
setprop "OAPA_STEPS_PER_ARCMIN.STEPS_AZ=100;STEPS_ALT=200"
clear_wire
setprop "PAC_MANUAL_ADJUSTMENT.MANUAL_AZ_STEP=0.1;MANUAL_ALT_STEP=0"
wait_state PAC_MANUAL_ADJUSTMENT 10 Alert && pass "stall detected" || fail "stall detected: $(state PAC_MANUAL_ADJUSTMENT)"
wire 'CMD !' && pass "stall sends !" || fail "stall sends !"
disconnect

# 11. Old firmware without V: still connects (the driver only warns).
start_fake --version ""
connect && pass "connect without V: field" || fail "connect without V: field"
[ "$(getprop FIRMWARE_INFO.VERSION)" = "Unknown" ] \
    && pass "missing version shown as Unknown" || fail "missing version shown as Unknown: $(getprop FIRMWARE_INFO.VERSION)"
disconnect

echo
[ $FAILS -eq 0 ] && echo "ALL PASS" || echo "$FAILS FAILURE(S)"
exit $FAILS
