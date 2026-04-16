#!/bin/bash
# Wrapper script to safely launch OAPA automation in Ekos Post-Startup
# This disconnects the script from Ekos so Ekos doesn't hang waiting for it to finish.

nohup /home/pi/.gemini/antigravity/scratch/indi-oapa/oapa_closed_loop.sh > /tmp/oapa_automation.log 2>&1 < /dev/null &
disown
exit 0
