#!/usr/bin/env bash
# switch-profile.sh — Manual radio profile override
#
# Normally, pirelay-detect-hat.service auto-detects which LoRa HAT is
# plugged in at boot and starts the matching target. Use this script to
# force a profile without rebooting, or to re-run detection after
# swapping hats at runtime (not recommended — power-cycle instead).
#
# Usage:
#   switch-profile.sh lora-mesh         # force Reticulum / SX1262
#   switch-profile.sh lorawan-gateway   # force ChirpStack / WM1302
#   switch-profile.sh detect            # re-run auto-detection
#   switch-profile.sh both-off          # stop both targets
#   switch-profile.sh status            # show current profile

set -euo pipefail

PROFILE_FILE=/run/pirelay/radio-profile

write_profile() {
    mkdir -p "$(dirname "${PROFILE_FILE}")"
    echo "$1" > "${PROFILE_FILE}"
}

case "${1:-}" in
  lora-mesh)
    systemctl stop lorawan-gateway.target 2>/dev/null || true
    systemctl start lora-mesh.target
    write_profile lora-mesh
    echo "Active profile: lora-mesh"
    ;;
  lorawan-gateway)
    systemctl stop lora-mesh.target 2>/dev/null || true
    systemctl start lorawan-gateway.target
    write_profile lorawan-gateway
    echo "Active profile: lorawan-gateway"
    ;;
  detect)
    systemctl restart pirelay-detect-hat.service
    sleep 1
    cat "${PROFILE_FILE}" 2>/dev/null || echo "unknown"
    ;;
  both-off)
    systemctl stop lorawan-gateway.target lora-mesh.target 2>/dev/null || true
    write_profile none
    echo "All radio profiles stopped"
    ;;
  status)
    if [ -r "${PROFILE_FILE}" ]; then
      echo "Current profile: $(cat "${PROFILE_FILE}")"
    else
      echo "Current profile: unknown (detection not yet run)"
    fi
    systemctl is-active lora-mesh.target 2>/dev/null | sed 's/^/lora-mesh.target: /' || true
    systemctl is-active lorawan-gateway.target 2>/dev/null | sed 's/^/lorawan-gateway.target: /' || true
    ;;
  *)
    echo "Usage: $0 {lora-mesh|lorawan-gateway|detect|both-off|status}" >&2
    exit 1
    ;;
esac
