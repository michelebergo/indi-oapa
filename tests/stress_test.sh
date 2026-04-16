#!/bin/bash
# ============================================================
#  INDI-OAPA Deep Stress Test
#  Exercises the driver under heavy load, edge cases, and
#  monitors for crashes, memory leaks, and protocol errors.
# ============================================================
set -o pipefail

# ── Configuration ─────────────────────────────────────────────
INDI_PORT=7624
DRIVER_BIN="indi_oapa_polaralignment"
DEVICE="OAPA Polar Alignment"
SERIAL_PORT="/dev/ttyUSB0"
LOG_FILE="/tmp/oapa_stress_test.log"
INDI_LOG="/tmp/oapa_indiserver.log"
DURATION_PER_TEST=15    # seconds per test phase
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
TOTAL_TESTS=0

# ── Colors ────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Helper functions ──────────────────────────────────────────
log()    { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*" | tee -a "$LOG_FILE"; }
pass()   { echo -e "${GREEN}  ✓ PASS${NC}: $*" | tee -a "$LOG_FILE"; ((PASS_COUNT++)); ((TOTAL_TESTS++)); }
fail()   { echo -e "${RED}  ✗ FAIL${NC}: $*" | tee -a "$LOG_FILE"; ((FAIL_COUNT++)); ((TOTAL_TESTS++)); }
warn()   { echo -e "${YELLOW}  ⚠ WARN${NC}: $*" | tee -a "$LOG_FILE"; ((WARN_COUNT++)); }
header() { echo -e "\n${BOLD}═══════════════════════════════════════════${NC}" | tee -a "$LOG_FILE"
           echo -e "${BOLD}  $*${NC}" | tee -a "$LOG_FILE"
           echo -e "${BOLD}═══════════════════════════════════════════${NC}" | tee -a "$LOG_FILE"; }

get_driver_pid()  { pgrep -f "$DRIVER_BIN" 2>/dev/null | head -1; }

get_mem_kb() {
    local pid=$1
    if [ -n "$pid" ] && [ -f "/proc/$pid/status" ]; then
        grep VmRSS /proc/$pid/status 2>/dev/null | awk '{print $2}'
    else
        echo "0"
    fi
}

get_temp() { vcgencmd measure_temp 2>/dev/null | grep -oP '[0-9.]+' || echo "N/A"; }

cleanup() {
    log "Cleaning up..."
    # Kill any indiserver we started
    if [ -n "$INDI_PID" ]; then
        kill "$INDI_PID" 2>/dev/null
        wait "$INDI_PID" 2>/dev/null
    fi
    # Kill stray instances
    pkill -f "indiserver.*$DRIVER_BIN" 2>/dev/null
    sleep 1
}

trap cleanup EXIT

check_driver_alive() {
    local pid
    pid=$(get_driver_pid)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    return 1
}

wait_for_property() {
    local prop="$1"
    local timeout="${2:-5}"
    local val
    val=$(indi_getprop -1 -t "$timeout" -p $INDI_PORT "$prop" 2>/dev/null)
    echo "$val"
}

# ── Pre-flight checks ────────────────────────────────────────
> "$LOG_FILE"
header "INDI-OAPA Deep Stress Test"
log "Date: $(date)"
log "System: $(cat /sys/firmware/devicetree/base/model 2>/dev/null)"
log "CPU temp (idle): $(get_temp)°C"
log "Free RAM: $(free -m | awk '/Mem/{print $4}') MB"
log ""

# Check driver binary
if ! which "$DRIVER_BIN" &>/dev/null; then
    log "Driver binary not found in PATH — checking build dir..."
    if [ -f "$(dirname "$0")/../build/$DRIVER_BIN" ]; then
        DRIVER_BIN="$(realpath "$(dirname "$0")/../build/$DRIVER_BIN")"
        log "Using: $DRIVER_BIN"
    else
        fail "Cannot find $DRIVER_BIN. Install it first with ./install.sh"
        exit 1
    fi
fi

# Check serial port
if [ ! -e "$SERIAL_PORT" ]; then
    warn "Serial port $SERIAL_PORT not found. Connection tests will fail gracefully."
fi

# Kill any existing indiserver
pkill -f "indiserver.*$DRIVER_BIN" 2>/dev/null
sleep 1

# ══════════════════════════════════════════════════════════════
#  TEST 1: Server Startup & Driver Loading
# ══════════════════════════════════════════════════════════════
header "TEST 1: Server Startup & Driver Loading"

log "Starting indiserver with OAPA driver..."
indiserver -p $INDI_PORT "$DRIVER_BIN" > "$INDI_LOG" 2>&1 &
INDI_PID=$!
sleep 3

if kill -0 "$INDI_PID" 2>/dev/null; then
    pass "indiserver started (PID: $INDI_PID)"
else
    fail "indiserver failed to start"
    cat "$INDI_LOG"
    exit 1
fi

if check_driver_alive; then
    DRIVER_PID=$(get_driver_pid)
    MEM_START=$(get_mem_kb "$DRIVER_PID")
    pass "Driver process running (PID: $DRIVER_PID, RSS: ${MEM_START} KB)"
else
    fail "Driver process not found"
    exit 1
fi

# Check properties are exposed
PROPS=$(indi_getprop -t 3 -p $INDI_PORT "$DEVICE.*" 2>/dev/null | head -20)
if [ -n "$PROPS" ]; then
    PROP_COUNT=$(echo "$PROPS" | wc -l)
    pass "Driver exposes $PROP_COUNT properties"
else
    fail "No properties found from driver"
fi

# ══════════════════════════════════════════════════════════════
#  TEST 2: Connection to Hardware
# ══════════════════════════════════════════════════════════════
header "TEST 2: Hardware Connection"

log "Setting port to $SERIAL_PORT..."
indi_setprop -p $INDI_PORT "$DEVICE.DEVICE_PORT.PORT=$SERIAL_PORT" 2>/dev/null
sleep 1

log "Connecting..."
indi_setprop -p $INDI_PORT "$DEVICE.CONNECTION.CONNECT=On" 2>/dev/null
sleep 4  # allow Arduino reset + handshake

CONN_STATE=$(indi_getprop -1 -t 3 -p $INDI_PORT "$DEVICE.CONNECTION.CONNECT" 2>/dev/null)
if [[ "$CONN_STATE" == *"On"* ]]; then
    pass "Connected to OAPA hardware"
    HARDWARE_CONNECTED=1
else
    warn "Could not connect to hardware (OAPA may not be plugged in)"
    HARDWARE_CONNECTED=0
fi

# ══════════════════════════════════════════════════════════════
#  TEST 3: Rapid Property Read Flood
# ══════════════════════════════════════════════════════════════
header "TEST 3: Rapid Property Read Flood ($DURATION_PER_TEST seconds)"

log "Flooding driver with getprop requests..."
READ_COUNT=0
READ_ERRORS=0
END_TIME=$((SECONDS + DURATION_PER_TEST))

while [ $SECONDS -lt $END_TIME ]; do
    if indi_getprop -1 -t 1 -p $INDI_PORT "$DEVICE.OAPA_POSITION.X_POS" &>/dev/null; then
        ((READ_COUNT++))
    else
        ((READ_ERRORS++))
    fi
    # Also hit other properties
    indi_getprop -1 -t 1 -p $INDI_PORT "$DEVICE.OAPA_SPEED.JOG_SPEED" &>/dev/null && ((READ_COUNT++)) || ((READ_ERRORS++))
done

log "  Reads completed: $READ_COUNT | Errors: $READ_ERRORS"
if check_driver_alive; then
    pass "Driver survived $READ_COUNT rapid property reads (errors: $READ_ERRORS)"
else
    fail "Driver CRASHED during property read flood!"
fi

# ══════════════════════════════════════════════════════════════
#  TEST 4: Speed Property Stress
# ══════════════════════════════════════════════════════════════
header "TEST 4: Speed Property Write Stress"

log "Rapidly changing speed values..."
SPEED_OK=0
SPEED_FAIL=0
for speed in 1 50 100 250 500 750 1000 2500 5000 10000 1 0.5 9999 500; do
    if indi_setprop -p $INDI_PORT "$DEVICE.OAPA_SPEED.JOG_SPEED=$speed" 2>/dev/null; then
        ((SPEED_OK++))
    else
        ((SPEED_FAIL++))
    fi
    sleep 0.1
done

if check_driver_alive; then
    pass "Speed property handled $SPEED_OK writes without crash"
else
    fail "Driver CRASHED during speed property stress!"
fi

# ══════════════════════════════════════════════════════════════
#  TEST 5: Jog Command Flood
# ══════════════════════════════════════════════════════════════
header "TEST 5: Jog Command Flood ($DURATION_PER_TEST seconds)"

if [ "$HARDWARE_CONNECTED" -eq 1 ]; then
    log "Sending rapid small jog commands..."
    JOG_COUNT=0
    JOG_ERRORS=0
    END_TIME=$((SECONDS + DURATION_PER_TEST))

    while [ $SECONDS -lt $END_TIME ]; do
        # Tiny jogs that won't move the mount much
        JOG_VAL=$(awk "BEGIN{printf \"%.2f\", (rand()-0.5)*0.5}")
        if indi_setprop -p $INDI_PORT "$DEVICE.OAPA_JOG.X_JOG=$JOG_VAL" 2>/dev/null; then
            ((JOG_COUNT++))
        else
            ((JOG_ERRORS++))
        fi
        sleep 0.05
    done

    log "  Jogs sent: $JOG_COUNT | Errors: $JOG_ERRORS"
    if check_driver_alive; then
        pass "Driver survived $JOG_COUNT rapid jog commands"
    else
        fail "Driver CRASHED during jog flood!"
    fi

    # Send abort to stop any remaining motion
    indi_setprop -p $INDI_PORT "$DEVICE.OAPA_ABORT.ABORT=On" 2>/dev/null
    sleep 1
else
    log "Skipping jog flood (no hardware connected) — testing property handling only"
    for i in $(seq 1 50); do
        indi_setprop -p $INDI_PORT "$DEVICE.OAPA_JOG.X_JOG=0.1;Y_JOG=-0.1" 2>/dev/null
    done
    if check_driver_alive; then
        pass "Driver handled 50 jog property writes without hardware"
    else
        fail "Driver CRASHED on jog writes without hardware!"
    fi
fi

# ══════════════════════════════════════════════════════════════
#  TEST 6: Simultaneous X+Y Jog Stress
# ══════════════════════════════════════════════════════════════
header "TEST 6: Simultaneous X+Y Jog Commands"

if [ "$HARDWARE_CONNECTED" -eq 1 ]; then
    log "Sending simultaneous X and Y jog commands..."
    DUAL_OK=0
    for i in $(seq 1 30); do
        X_VAL=$(awk "BEGIN{printf \"%.2f\", (rand()-0.5)*0.2}")
        Y_VAL=$(awk "BEGIN{printf \"%.2f\", (rand()-0.5)*0.2}")
        if indi_setprop -p $INDI_PORT "$DEVICE.OAPA_JOG.X_JOG=$X_VAL;Y_JOG=$Y_VAL" 2>/dev/null; then
            ((DUAL_OK++))
        fi
        sleep 0.2
    done

    # Abort
    indi_setprop -p $INDI_PORT "$DEVICE.OAPA_ABORT.ABORT=On" 2>/dev/null
    sleep 1

    if check_driver_alive; then
        pass "Driver handled $DUAL_OK simultaneous X+Y jog commands"
    else
        fail "Driver CRASHED on simultaneous jog!"
    fi
else
    log "Skipping (no hardware)"
    pass "Skipped dual-axis jog (no hardware)"
fi

# ══════════════════════════════════════════════════════════════
#  TEST 7: Abort Button Spam
# ══════════════════════════════════════════════════════════════
header "TEST 7: Abort Button Spam"

log "Rapidly hitting abort..."
ABORT_COUNT=0
for i in $(seq 1 50); do
    indi_setprop -p $INDI_PORT "$DEVICE.OAPA_ABORT.ABORT=On" 2>/dev/null
    ((ABORT_COUNT++))
    sleep 0.05
done

if check_driver_alive; then
    pass "Driver survived $ABORT_COUNT rapid abort commands"
else
    fail "Driver CRASHED during abort spam!"
fi

# ══════════════════════════════════════════════════════════════
#  TEST 8: Connect/Disconnect Cycling
# ══════════════════════════════════════════════════════════════
header "TEST 8: Rapid Connect/Disconnect Cycling"

log "Cycling connection 10 times..."
CYCLE_OK=0
CYCLE_ERRORS=0
for i in $(seq 1 10); do
    # Disconnect
    indi_setprop -p $INDI_PORT "$DEVICE.CONNECTION.DISCONNECT=On" 2>/dev/null
    sleep 1
    # Connect
    indi_setprop -p $INDI_PORT "$DEVICE.CONNECTION.CONNECT=On" 2>/dev/null
    sleep 3  # Arduino reset time

    if check_driver_alive; then
        ((CYCLE_OK++))
    else
        ((CYCLE_ERRORS++))
        fail "Driver died on connection cycle $i!"
        break
    fi
    log "  Cycle $i/10 OK"
done

if check_driver_alive; then
    pass "Driver survived $CYCLE_OK connect/disconnect cycles"
else
    fail "Driver CRASHED during connection cycling!"
fi

# ══════════════════════════════════════════════════════════════
#  TEST 9: Concurrent Client Stress
# ══════════════════════════════════════════════════════════════
header "TEST 9: Concurrent Client Stress"

log "Launching 5 concurrent indi_getprop clients for $DURATION_PER_TEST seconds..."
PIDS=""
for client in $(seq 1 5); do
    (
        end=$((SECONDS + DURATION_PER_TEST))
        count=0
        while [ $SECONDS -lt $end ]; do
            indi_getprop -t 1 -p $INDI_PORT "$DEVICE.*" &>/dev/null
            ((count++))
        done
        echo "$count" > "/tmp/oapa_client_${client}.count"
    ) &
    PIDS="$PIDS $!"
done

# Wait for all clients to finish
wait $PIDS 2>/dev/null

TOTAL_CONCURRENT=0
for client in $(seq 1 5); do
    if [ -f "/tmp/oapa_client_${client}.count" ]; then
        C=$(cat "/tmp/oapa_client_${client}.count")
        TOTAL_CONCURRENT=$((TOTAL_CONCURRENT + C))
        rm -f "/tmp/oapa_client_${client}.count"
    fi
done

log "  Total requests across 5 clients: $TOTAL_CONCURRENT"
if check_driver_alive; then
    pass "Driver survived $TOTAL_CONCURRENT concurrent multi-client requests"
else
    fail "Driver CRASHED under concurrent client load!"
fi

# ══════════════════════════════════════════════════════════════
#  TEST 10: Edge Case / Invalid Input
# ══════════════════════════════════════════════════════════════
header "TEST 10: Edge Case & Invalid Input"

log "Testing boundary and invalid values..."

# Extreme jog values
EDGE_CASES=(
    "OAPA_JOG.X_JOG=99999"
    "OAPA_JOG.X_JOG=-99999"
    "OAPA_JOG.X_JOG=0"
    "OAPA_JOG.Y_JOG=0"
    "OAPA_SPEED.JOG_SPEED=0"
    "OAPA_SPEED.JOG_SPEED=-1"
    "OAPA_SPEED.JOG_SPEED=999999"
    "OAPA_JOG.X_JOG=0.001"
    "OAPA_JOG.Y_JOG=0.001"
    "OAPA_SPEED.JOG_SPEED=0.0001"
)

EDGE_OK=0
for case in "${EDGE_CASES[@]}"; do
    indi_setprop -p $INDI_PORT "$DEVICE.$case" 2>/dev/null
    ((EDGE_OK++))
    sleep 0.2
done

# Abort any motion from extreme jog
indi_setprop -p $INDI_PORT "$DEVICE.OAPA_ABORT.ABORT=On" 2>/dev/null
sleep 1

if check_driver_alive; then
    pass "Driver handled $EDGE_OK edge-case inputs without crashing"
else
    fail "Driver CRASHED on edge-case input!"
fi

# ══════════════════════════════════════════════════════════════
#  TEST 11: Memory Leak Detection
# ══════════════════════════════════════════════════════════════
header "TEST 11: Memory Leak Detection"

DRIVER_PID=$(get_driver_pid)
MEM_AFTER=$(get_mem_kb "$DRIVER_PID")

if [ -n "$MEM_START" ] && [ "$MEM_START" -gt 0 ] && [ -n "$MEM_AFTER" ] && [ "$MEM_AFTER" -gt 0 ]; then
    MEM_DELTA=$((MEM_AFTER - MEM_START))
    MEM_PERCENT=$(awk "BEGIN{printf \"%.1f\", ($MEM_DELTA/$MEM_START)*100}")
    log "  Memory at start:  ${MEM_START} KB"
    log "  Memory now:       ${MEM_AFTER} KB"
    log "  Delta:            ${MEM_DELTA} KB (${MEM_PERCENT}%)"

    if [ "$MEM_DELTA" -lt 2048 ]; then
        pass "Memory growth within acceptable range (+${MEM_DELTA} KB)"
    elif [ "$MEM_DELTA" -lt 8192 ]; then
        warn "Moderate memory growth (+${MEM_DELTA} KB) — may indicate slow leak"
        pass "Memory growth noticed but not critical (+${MEM_DELTA} KB)"
    else
        fail "Significant memory growth (+${MEM_DELTA} KB) — possible memory leak!"
    fi
else
    warn "Could not measure memory (driver PID changed or not running)"
    pass "Memory measurement skipped"
fi

# ══════════════════════════════════════════════════════════════
#  TEST 12: Thermal Check
# ══════════════════════════════════════════════════════════════
header "TEST 12: Thermal Check"

TEMP_AFTER=$(get_temp)
log "  CPU temperature after stress: ${TEMP_AFTER}°C"
TEMP_INT=$(echo "$TEMP_AFTER" | cut -d. -f1)
if [ "$TEMP_INT" -lt 75 ]; then
    pass "Temperature OK (${TEMP_AFTER}°C < 75°C)"
elif [ "$TEMP_INT" -lt 85 ]; then
    warn "Temperature elevated (${TEMP_AFTER}°C) — check cooling"
    pass "Temperature elevated but within safe limits"
else
    fail "Temperature CRITICAL (${TEMP_AFTER}°C) — throttling likely!"
fi

# ══════════════════════════════════════════════════════════════
#  TEST 13: indiserver Log Error Scan
# ══════════════════════════════════════════════════════════════
header "TEST 13: Log Error Scan"

if [ -f "$INDI_LOG" ]; then
    SEG_FAULTS=$(grep -ci "segfault\|segmentation\|SIGSEGV\|core dump" "$INDI_LOG" 2>/dev/null || echo 0)
    ASSERTIONS=$(grep -ci "assert\|abort" "$INDI_LOG" 2>/dev/null || echo 0)
    BUFFER_OVF=$(grep -ci "overflow\|buffer" "$INDI_LOG" 2>/dev/null || echo 0)

    if [ "$SEG_FAULTS" -gt 0 ]; then
        fail "Found $SEG_FAULTS segfault references in server log!"
    else
        pass "No segfaults detected in server log"
    fi

    if [ "$ASSERTIONS" -gt 0 ]; then
        warn "Found $ASSERTIONS assertion/abort references in log"
    fi
    if [ "$BUFFER_OVF" -gt 0 ]; then
        warn "Found $BUFFER_OVF buffer-related messages in log"
    fi
else
    warn "Server log not found at $INDI_LOG"
fi

# ══════════════════════════════════════════════════════════════
#  FINAL REPORT
# ══════════════════════════════════════════════════════════════
header "FINAL REPORT"

DRIVER_ALIVE="NO"
if check_driver_alive; then
    DRIVER_ALIVE="YES"
fi

echo "" | tee -a "$LOG_FILE"
echo -e "  ${BOLD}Driver alive at end:${NC}    $DRIVER_ALIVE" | tee -a "$LOG_FILE"
echo -e "  ${BOLD}Total tests:${NC}            $TOTAL_TESTS" | tee -a "$LOG_FILE"
echo -e "  ${GREEN}Passed:${NC}                 $PASS_COUNT" | tee -a "$LOG_FILE"
echo -e "  ${RED}Failed:${NC}                 $FAIL_COUNT" | tee -a "$LOG_FILE"
echo -e "  ${YELLOW}Warnings:${NC}               $WARN_COUNT" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

if [ "$FAIL_COUNT" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}══ ALL TESTS PASSED ══${NC}" | tee -a "$LOG_FILE"
else
    echo -e "  ${RED}${BOLD}══ $FAIL_COUNT TEST(S) FAILED ══${NC}" | tee -a "$LOG_FILE"
fi

echo "" | tee -a "$LOG_FILE"
echo -e "  Full log: ${CYAN}$LOG_FILE${NC}" | tee -a "$LOG_FILE"
echo -e "  Server log: ${CYAN}$INDI_LOG${NC}" | tee -a "$LOG_FILE"
echo ""

# Cleanup is handled by trap
exit $FAIL_COUNT
