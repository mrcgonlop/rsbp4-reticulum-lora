#!/usr/bin/env bash
# flash-rnode.sh — Flash SX1262 LoRa hat with RNode firmware
# Run once after initial hardware setup. Ensure SX1262 hat is enabled.

set -euo pipefail

RNODE_PORT="${1:-/dev/ttyS0}"
SX1262_RST=22

echo "=== RNode Firmware Flash ==="
echo "Target port: ${RNODE_PORT}"
echo ""

# Ensure SX1262 is in reset state, then release
if [ ! -d /sys/class/gpio/gpio${SX1262_RST} ]; then
    echo "${SX1262_RST}" > /sys/class/gpio/export
    sleep 0.1
fi
echo "out" > /sys/class/gpio/gpio${SX1262_RST}/direction
echo "0" > /sys/class/gpio/gpio${SX1262_RST}/value
sleep 0.2
echo "1" > /sys/class/gpio/gpio${SX1262_RST}/value
sleep 0.5

echo "Starting RNode auto-install on ${RNODE_PORT}..."
rnodeconf "${RNODE_PORT}" --autoinstall

echo ""
echo "Flash complete. Verify with:"
echo "  rnodeconf ${RNODE_PORT} --info"
