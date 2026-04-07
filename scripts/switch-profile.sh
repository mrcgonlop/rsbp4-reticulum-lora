#!/usr/bin/env bash
# switch-profile.sh — Switch between radio profiles on stacked LoRa hats
# Usage: switch-profile.sh {lorawan-gateway|lora-mesh|both-off}

set -euo pipefail

WM1302_RST=17
SX1262_RST=22

gpio_set() { echo "$2" > /sys/class/gpio/gpio$1/value; }
gpio_export() {
  [ -d /sys/class/gpio/gpio$1 ] || echo "$1" > /sys/class/gpio/export
  echo "out" > /sys/class/gpio/gpio$1/direction
}

gpio_export $WM1302_RST
gpio_export $SX1262_RST

case "${1:-}" in
  lorawan-gateway)
    systemctl stop lora-mesh.target 2>/dev/null || true
    gpio_set $SX1262_RST 0   # disable SX1262
    gpio_set $WM1302_RST 1   # enable WM1302
    sleep 0.5
    systemctl start lorawan-gateway.target
    echo "Active profile: lorawan-gateway"
    ;;
  lora-mesh)
    systemctl stop lorawan-gateway.target 2>/dev/null || true
    gpio_set $WM1302_RST 0   # disable WM1302
    gpio_set $SX1262_RST 1   # enable SX1262
    sleep 0.5
    systemctl start lora-mesh.target
    echo "Active profile: lora-mesh"
    ;;
  both-off)
    systemctl stop lorawan-gateway.target 2>/dev/null || true
    systemctl stop lora-mesh.target 2>/dev/null || true
    gpio_set $WM1302_RST 0
    gpio_set $SX1262_RST 0
    echo "All radios disabled"
    ;;
  *)
    echo "Usage: $0 {lorawan-gateway|lora-mesh|both-off}" >&2
    exit 1
    ;;
esac
