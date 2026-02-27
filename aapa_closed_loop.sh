#!/bin/bash
# AAPA Closed-Loop Polar Alignment Automation Script
# Supports three modes:
#   Default (--no-daemon)  : auto loop via KStars D-Bus (fully independent)
#   --correct <az> <alt>   : one-shot correction in arcseconds
#   --interactive           : interactive loop (type values from Ekos screen)

INDI_PORT=7624
AAPA_DEVICE="AAPA Polar Alignment"
DBUS_ADDR="unix:path=/run/user/1000/bus"

# Threshold in arcseconds. Stop correcting if error is below this.
THRESHOLD_ARCSEC=20

# ─────────────────────────────────────────────
# Helper: send correction in degrees to AAPA_PAA_ERROR property
# ─────────────────────────────────────────────
send_paa_correction() {
    local az_deg=$1
    local alt_deg=$2
    echo "  → Sending PAA correction: Az=${az_deg}°  Alt=${alt_deg}°"
    indi_setprop -p $INDI_PORT "${AAPA_DEVICE}.AAPA_PAA_ERROR.AZ_ERR=${az_deg};ALT_ERR=${alt_deg}"
}

# ─────────────────────────────────────────────
# Helper: read current PAA error from KStars D-Bus logText
# Returns: "<az_arcsec> <alt_arcsec>" or "" if not found
# ─────────────────────────────────────────────
get_paa_error_dbus() {
    local logtext
    logtext=$(DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" dbus-send \
        --session --print-reply --dest=org.kde.kstars \
        /KStars/Ekos/Align \
        org.freedesktop.DBus.Properties.Get \
        string:"org.kde.kstars.Ekos.Align" string:"logText" 2>/dev/null)

    # Extract the most recent "Polar Alignment Error" line
    local paa_line
    paa_line=$(echo "$logtext" | grep "Polar Alignment Error" | tail -1)
    [[ -z "$paa_line" ]] && return 1

    # Parse: "Azimuth:  00° 00' 12"" and "Altitude:  00° 00' 07""
    local az_d az_m az_s alt_d alt_m alt_s
    az_d=$(echo  "$paa_line" | grep -oP 'Azimuth:\s+\K\d+(?=°)')
    az_m=$(echo  "$paa_line" | grep -oP "Azimuth:.*?°\s+\K\d+(?=')")
    az_s=$(echo  "$paa_line" | grep -oP "Azimuth:.*?'\\s+\\K\\d+(?=\")")
    alt_d=$(echo "$paa_line" | grep -oP 'Altitude:\s+\K\d+(?=°)')
    alt_m=$(echo "$paa_line" | grep -oP "Altitude:.*?°\s+\K\d+(?=')")
    alt_s=$(echo "$paa_line" | grep -oP "Altitude:.*?'\\s+\\K\\d+(?=\")")

    local az_arcsec alt_arcsec
    az_arcsec=$(awk  -v d="${az_d:-0}"  -v m="${az_m:-0}"  -v s="${az_s:-0}"  'BEGIN{print d*3600+m*60+s}')
    alt_arcsec=$(awk -v d="${alt_d:-0}" -v m="${alt_m:-0}" -v s="${alt_s:-0}" 'BEGIN{print d*3600+m*60+s}')
    echo "$az_arcsec $alt_arcsec"
}

# ─────────────────────────────────────────────
# Mode: --correct <az_arcsec> <alt_arcsec>
# ─────────────────────────────────────────────
if [[ "$1" == "--correct" ]]; then
    AZ_ARCSEC=${2:-0}
    ALT_ARCSEC=${3:-0}
    AZ_DEG=$(awk  -v a="$AZ_ARCSEC"  'BEGIN{printf "%.6f", a/3600}')
    ALT_DEG=$(awk -v a="$ALT_ARCSEC" 'BEGIN{printf "%.6f", a/3600}')
    echo "AAPA PAA One-Shot Correction"
    echo "  Input: Az=${AZ_ARCSEC}\"  Alt=${ALT_ARCSEC}\""
    send_paa_correction "$AZ_DEG" "$ALT_DEG"
    echo "Done."
    exit 0
fi

# ─────────────────────────────────────────────
# Mode: --interactive
# ─────────────────────────────────────────────
if [[ "$1" == "--interactive" ]]; then
    echo "AAPA Interactive PAA Correction Loop"
    echo "After each Ekos solve, type the Az/Alt arcsecond values shown in the Ekos PAA screen."
    echo "Use negative for opposite direction. Enter 0 to stop."
    while true; do
        echo ""
        read -r -p "Azimuth error in arcseconds [0 = done]: " AZ_ARCSEC
        [[ "$AZ_ARCSEC" == "0" || -z "$AZ_ARCSEC" ]] && break
        read -r -p "Altitude error in arcseconds:           " ALT_ARCSEC
        AZ_DEG=$(awk  -v a="$AZ_ARCSEC"  'BEGIN{printf "%.6f", a/3600}')
        ALT_DEG=$(awk -v a="$ALT_ARCSEC" 'BEGIN{printf "%.6f", a/3600}')
        send_paa_correction "$AZ_DEG" "$ALT_DEG"
        echo "Motors moving... waiting 10 seconds for Ekos to refresh image."
        sleep 10
    done
    echo "Correction loop ended."
    exit 0
fi

# ─────────────────────────────────────────────
# Mode: --no-daemon (default auto loop via D-Bus)
# ─────────────────────────────────────────────
if [[ "$1" != "--no-daemon" ]]; then
    echo "AAPA Automation: Backgrounding loop..."
    nohup $0 --no-daemon </dev/null >/tmp/aapa_automation.log 2>&1 &
    exit 0
fi

echo "Starting AAPA Auto Closed-Loop Automation (D-Bus mode)..."
echo "Waiting 10 seconds for Ekos to finish establishing its connections..."
sleep 10
echo "Monitoring KStars Align log for PAA solution..."

LAST_LINE=""

while true; do
    RESULT=$(get_paa_error_dbus)
    if [[ -z "$RESULT" ]]; then
        sleep 2
        continue
    fi

    # Skip if we already processed this exact result
    if [[ "$RESULT" == "$LAST_LINE" ]]; then
        sleep 2
        continue
    fi
    LAST_LINE="$RESULT"

    AZ_ARCSEC=$(echo "$RESULT" | awk '{print $1}')
    ALT_ARCSEC=$(echo "$RESULT" | awk '{print $2}')

    echo "Current Error → Azimuth: ${AZ_ARCSEC}\"  Altitude: ${ALT_ARCSEC}\""

    # Check if below threshold
    AZ_DONE=$(awk  -v v="$AZ_ARCSEC"  -v t=$THRESHOLD_ARCSEC 'BEGIN{print (v<t && v>-t) ? 1 : 0}')
    ALT_DONE=$(awk -v v="$ALT_ARCSEC" -v t=$THRESHOLD_ARCSEC 'BEGIN{print (v<t && v>-t) ? 1 : 0}')

    if [[ "$AZ_DONE" -eq 1 && "$ALT_DONE" -eq 1 ]]; then
        echo "Successfully Aligned! Error (Az:${AZ_ARCSEC}\", Alt:${ALT_ARCSEC}\") is below threshold ${THRESHOLD_ARCSEC}\""
        break
    fi

    AZ_DEG=$(awk  -v a="$AZ_ARCSEC"  'BEGIN{printf "%.6f", a/3600}')
    ALT_DEG=$(awk -v a="$ALT_ARCSEC" 'BEGIN{printf "%.6f", a/3600}')
    send_paa_correction "$AZ_DEG" "$ALT_DEG"

    echo "Waiting 10 seconds for Ekos to refresh image..."
    sleep 10
done
