#!/bin/bash
# ============================================================
#  INDI-OAPA Uninstaller
#  Removes the files installed by install.sh, including those
#  left by driver 1.x.
# ============================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: please run as root (sudo ./uninstall.sh)${NC}"
    exit 1
fi

echo -e "${YELLOW}Removing INDI-OAPA files...${NC}"

FILES=(
    /usr/bin/indi_oapa
    /usr/share/indi/indi_oapa.xml
    # driver 1.x
    /usr/bin/indi_oapa_polaralignment
    /usr/share/indi/indi_oapa_polaralignment.xml
    /usr/local/bin/oapa_closed_loop.sh
    /usr/local/bin/auto_oapa.sh
)

for f in "${FILES[@]}"; do
    if [ -f "$f" ]; then
        rm -f "$f"
        echo "  removed $f"
    fi
done

echo ""
echo -e "${GREEN}Uninstall complete.${NC}"
