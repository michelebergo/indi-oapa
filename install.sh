#!/bin/bash
# ============================================================
#  INDI-AAPA Installer
#  One-click build & install for Debian/Ubuntu/Raspberry Pi OS
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   INDI-AAPA Installer                    ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""

# ── Check for root ────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Please run as root (sudo ./install.sh)${NC}"
    exit 1
fi

# ── Install dependencies ──────────────────────────────────────
echo -e "${YELLOW}[1/4] Checking dependencies...${NC}"
DEPS="cmake build-essential libindi-dev"
MISSING=""
for pkg in $DEPS; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        MISSING="$MISSING $pkg"
    fi
done

if [ -n "$MISSING" ]; then
    echo "Installing missing packages:$MISSING"
    apt-get update -qq
    apt-get install -y $MISSING
else
    echo "All dependencies are already installed."
fi

# ── Build ─────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}[2/4] Building driver...${NC}"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
cmake -DCMAKE_INSTALL_PREFIX=/usr ..
make -j$(nproc)

# ── Install driver ────────────────────────────────────────────
echo ""
echo -e "${YELLOW}[3/4] Installing driver...${NC}"
make install

echo "  ✓ indi_aapa_polaralignment → /usr/bin/"
echo "  ✓ indi_aapa_polaralignment.xml → /usr/share/indi/"

# ── Install automation scripts ────────────────────────────────
echo ""
echo -e "${YELLOW}[4/4] Installing automation scripts...${NC}"
install -m 755 "$SCRIPT_DIR/aapa_closed_loop.sh" /usr/local/bin/aapa_closed_loop.sh
install -m 755 "$SCRIPT_DIR/auto_aapa.sh" /usr/local/bin/auto_aapa.sh

# Update the wrapper script to point to the installed location
sed -i 's|/home/.*/aapa_closed_loop.sh|/usr/local/bin/aapa_closed_loop.sh|' /usr/local/bin/auto_aapa.sh

echo "  ✓ aapa_closed_loop.sh → /usr/local/bin/"
echo "  ✓ auto_aapa.sh → /usr/local/bin/"

# ── Done ──────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Installation complete!                 ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo "Next steps:"
echo "  1. Open KStars → Ekos → Profile Editor"
echo "  2. Add 'AAPA Polar Alignment' under Auxiliary drivers"
echo "  3. Set the serial port (usually /dev/ttyUSB0)"
echo "  4. Connect and enjoy!"
echo ""
echo "For closed-loop automation, edit the calibration values in:"
echo "  /usr/local/bin/aapa_closed_loop.sh"
echo ""
echo -e "Report bugs at: ${YELLOW}https://github.com/michelebergo/indi-aapa/issues${NC}"
