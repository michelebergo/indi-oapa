#!/bin/bash
# ============================================================
#  INDI-OAPA Installer
#  Build & install for Debian/Ubuntu/Raspberry Pi OS
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}INDI-OAPA Installer${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: please run as root (sudo ./install.sh)${NC}"
    exit 1
fi

# ── Dependencies ──────────────────────────────────────────────
echo -e "${YELLOW}[1/4] Checking dependencies...${NC}"
DEPS="cmake build-essential libindi-dev"
MISSING=""
for pkg in $DEPS; do
    dpkg -s "$pkg" &>/dev/null || MISSING="$MISSING $pkg"
done
if [ -n "$MISSING" ]; then
    echo "Installing missing packages:$MISSING"
    apt-get update -qq
    apt-get install -y $MISSING
fi

# The PAC interface that Ekos drives appeared in INDI 2.2.0.
if [ ! -f /usr/include/libindi/indipacinterface.h ]; then
    echo -e "${RED}Error: your INDI library has no PAC interface. INDI >= 2.2.0 is required.${NC}"
    echo "On Ubuntu: sudo apt-add-repository ppa:mutlaqja/ppa && sudo apt update && sudo apt install libindi-dev"
    exit 1
fi

# ── Build ─────────────────────────────────────────────────────
echo -e "${YELLOW}[2/4] Building driver...${NC}"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
cmake -DCMAKE_INSTALL_PREFIX=/usr ..
make -j"$(nproc)"

# ── Remove files from driver 1.x ──────────────────────────────
echo -e "${YELLOW}[3/4] Removing files from the previous driver version (if any)...${NC}"
for f in /usr/bin/indi_oapa_polaralignment \
         /usr/share/indi/indi_oapa_polaralignment.xml \
         /usr/local/bin/oapa_closed_loop.sh \
         /usr/local/bin/auto_oapa.sh; do
    [ -f "$f" ] && rm -f "$f" && echo "  removed $f"
done

# ── Install ───────────────────────────────────────────────────
echo -e "${YELLOW}[4/4] Installing driver...${NC}"
make install
echo "  indi_oapa     -> /usr/bin/"
echo "  indi_oapa.xml -> /usr/share/indi/"

echo ""
echo -e "${GREEN}Installation complete.${NC}"
echo ""
echo "Next steps:"
echo "  1. KStars -> Ekos -> Profile Editor: add 'OAPA' under Auxiliary"
echo "  2. INDI Control Panel -> OAPA -> Connection: set the serial port, Connect"
echo "  3. Set Calibration (steps/arcmin) for both axes, then check the direction"
echo "  See README.md for details."
echo ""
echo -e "Report bugs at: ${YELLOW}https://github.com/michelebergo/indi-oapa/issues${NC}"
