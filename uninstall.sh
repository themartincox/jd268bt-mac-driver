#!/bin/bash
# Removes everything install.sh set up.
set -uo pipefail

APP_DIR="$HOME/Library/Application Support/JadensBTBridge"
LOG_DIR="$HOME/Library/Logs/JadensBTBridge"
PRINTER_QUEUE_NAME="JadensJD268BT"

echo "==> Stopping the bridge..."
pkill -f "JadensBTBridge/bridge.py" 2>/dev/null || true

echo "==> Removing login item..."
osascript -e 'tell application "System Events" to delete login item "StartJadensBridge.command"' 2>/dev/null || true

echo "==> Removing bridge files..."
rm -rf "$APP_DIR" "$LOG_DIR"

echo "==> Removing CUPS printer queue..."
lpadmin -x "$PRINTER_QUEUE_NAME" 2>/dev/null || true

echo "==> Removing driver files from /Library/Printers/Jadens (you'll be asked for your password)..."
osascript -e 'do shell script "rm -rf /Library/Printers/Jadens" with administrator privileges with prompt "This removes the Jadens JD-268BT driver files."' 2>/dev/null || true

echo "Done. The Bluetooth pairing itself is untouched - remove it from System Settings > Bluetooth if you want."
