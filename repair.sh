#!/bin/bash
# Fixes the most common failure: the printer's Bluetooth pairing gets out
# of sync with the Mac (often after a power cycle) - macOS still thinks
# it's paired, but the printer no longer trusts the connection, so every
# print job times out with "timed out opening RFCOMM channel" even though
# Bluetooth shows as "connected". Re-pairing from scratch fixes it.
set -euo pipefail

CONFIG_PATH="$HOME/Library/Application Support/JadensBTBridge/config.json"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "No config.json found - run install.sh first." >&2
  exit 1
fi

ADDRESS="$(python3 -c "import json; print(json.load(open('$CONFIG_PATH'))['address'])")"

echo "==> Disconnecting and unpairing $ADDRESS..."
blueutil --disconnect "$ADDRESS" 2>/dev/null || true
sleep 1
blueutil --unpair "$ADDRESS" || true
sleep 1

echo "==> Re-pairing (make sure the printer is on and nearby)..."
echo "0000" | blueutil --pair "$ADDRESS"
sleep 1
blueutil --connect "$ADDRESS" || true

echo "==> Restarting the bridge..."
pkill -f "JadensBTBridge/bridge.py" 2>/dev/null || true
sleep 1
open "$HOME/Library/Application Support/JadensBTBridge/StartJadensBridge.command"

echo "Done - try printing again."
