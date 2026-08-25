#!/bin/bash
# Installs wireless (Bluetooth) printing support for the Jadens JD-268BT
# label printer on macOS. See README.md for how this works.
set -euo pipefail

APP_DIR="$HOME/Library/Application Support/JadensBTBridge"
LOG_DIR="$HOME/Library/Logs/JadensBTBridge"
CONFIG_PATH="$APP_DIR/config.json"
COMMAND_FILE="$APP_DIR/StartJadensBridge.command"
PRINTER_QUEUE_NAME="JadensJD268BT"
PRINTER_DISPLAY_NAME="Jadens JD-268BT (Bluetooth)"
JADENS_DRIVER_PKG_URL="https://cdn.shopify.com/s/files/1/0574/8742/5675/files/Jadens-Printer-Driver_macos_3.3.6.506_90b9ffc8-6ec4-488a-977b-1e740f8d9023.pkg?v=1779690705"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "==> $*"; }

if [[ "$(uname)" != "Darwin" ]]; then
  echo "This installer is for macOS only." >&2
  exit 1
fi

if ! command -v python3 >/dev/null; then
  echo "python3 is required (install Xcode Command Line Tools: xcode-select --install)" >&2
  exit 1
fi

log "Installing Python Bluetooth dependencies (pyobjc)..."
python3 -m pip install --quiet --user pyobjc-core pyobjc-framework-IOBluetooth

if ! command -v blueutil >/dev/null; then
  if command -v brew >/dev/null; then
    log "Installing blueutil (Bluetooth CLI helper) via Homebrew..."
    brew install blueutil
  else
    echo "blueutil is required. Install Homebrew (https://brew.sh) then run: brew install blueutil" >&2
    exit 1
  fi
fi

mkdir -p "$APP_DIR" "$LOG_DIR"

# --- Find and pair the printer -------------------------------------------
ADDRESS="${JADENS_ADDRESS:-}"
if [[ -z "$ADDRESS" ]] && [[ -f "$CONFIG_PATH" ]]; then
  ADDRESS="$(python3 -c "import json; print(json.load(open('$CONFIG_PATH')).get('address',''))" 2>/dev/null || true)"
fi

if [[ -z "$ADDRESS" ]]; then
  log "Scanning for the printer over Bluetooth (make sure it's powered on)..."
  SCAN_OUTPUT="$(blueutil --inquiry 15)"
  ADDRESS="$(echo "$SCAN_OUTPUT" | grep -i "JD-268BT" | head -1 | sed -n 's/.*address: \([a-f0-9:-]*\).*/\1/p')"
  if [[ -z "$ADDRESS" ]]; then
    echo "Couldn't find a JD-268BT over Bluetooth. Make sure it's powered on and nearby, then re-run this script." >&2
    echo "Scan results were:" >&2
    echo "$SCAN_OUTPUT" >&2
    exit 1
  fi
  log "Found printer at $ADDRESS"
fi

if ! blueutil --info "$ADDRESS" 2>/dev/null | grep -q "paired"; then
  log "Pairing (using PIN 0000, the JD-268BT default)..."
  echo "0000" | blueutil --pair "$ADDRESS" || {
    echo "Pairing failed. Try pairing manually via System Settings > Bluetooth, then re-run this script." >&2
    exit 1
  }
fi
blueutil --connect "$ADDRESS" || true

# --- Install the bridge ----------------------------------------------------
log "Installing the bridge..."
cp "$SCRIPT_DIR/bridge.py" "$APP_DIR/bridge.py"
python3 -c "import json; json.dump({'address': '$ADDRESS'}, open('$CONFIG_PATH', 'w'), indent=2)"

cat > "$COMMAND_FILE" << EOF
#!/bin/bash
# Relays print jobs to the Jadens JD-268BT over Bluetooth.
# Runs as a real Terminal.app child so macOS grants it Bluetooth access
# (a plain background/login-agent process gets silently denied).
exec /usr/bin/python3 "$APP_DIR/bridge.py" >> "$LOG_DIR/bridge.log" 2>&1
EOF
chmod +x "$COMMAND_FILE"

log "Registering login item so the bridge starts automatically..."
osascript -e "tell application \"System Events\" to get the name of every login item" | grep -q "StartJadensBridge" || \
  osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$COMMAND_FILE\", hidden:false, name:\"JadensBTBridge\"}"

log "Starting the bridge now..."
pkill -f "JadensBTBridge/bridge.py" 2>/dev/null || true
sleep 1
open "$COMMAND_FILE"
sleep 2

# --- Install Jadens' official PPD + filter, register the CUPS queue -------
log "Downloading Jadens' official macOS driver (PPD + filter)..."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
curl -sL -o "$WORK/driver.pkg" "$JADENS_DRIVER_PKG_URL"
pkgutil --expand "$WORK/driver.pkg" "$WORK/expanded"
(cd "$WORK/expanded/Jadens.pkg" && gzip -dc Payload | cpio -id) >/dev/null 2>&1

PPD_SRC="$WORK/expanded/Jadens.pkg/Library/Printers/Jadens/PPDs/JD-268BT.ppd"
FILTER_SRC="$WORK/expanded/Jadens.pkg/Library/Printers/Jadens/Filter/rastertolabel"
if [[ ! -f "$PPD_SRC" || ! -f "$FILTER_SRC" ]]; then
  echo "Couldn't find JD-268BT.ppd or the rastertolabel filter in Jadens' installer." >&2
  echo "Their download page may have changed - check https://jadens.com/pages/jd268-download-and-video" >&2
  exit 1
fi

log "Installing the driver into /Library/Printers/Jadens (you'll be asked for your password)..."
INSTALL_CMD="mkdir -p /Library/Printers/Jadens/Filter /Library/Printers/Jadens/PPDs && \
cp '$FILTER_SRC' /Library/Printers/Jadens/Filter/rastertolabel && \
chmod 755 /Library/Printers/Jadens/Filter/rastertolabel && \
cp '$PPD_SRC' /Library/Printers/Jadens/PPDs/JD-268BT.ppd && \
chmod 644 /Library/Printers/Jadens/PPDs/JD-268BT.ppd && \
/usr/sbin/lpadmin -p $PRINTER_QUEUE_NAME -E -v socket://127.0.0.1:9100 \
  -P /Library/Printers/Jadens/PPDs/JD-268BT.ppd \
  -D '$PRINTER_DISPLAY_NAME' -L 'Wireless via Bluetooth bridge'"
osascript -e "do shell script \"$INSTALL_CMD\" with administrator privileges with prompt \"This installs the Jadens JD-268BT printer driver and registers it as a wireless printer.\""

lpoptions -p "$PRINTER_QUEUE_NAME" -o media=w288h432 -o PageSize=w288h432 -o MediaMethod=Direct

log "Done. \"$PRINTER_DISPLAY_NAME\" should now appear in the Print dialog of any app."
log "If a print job doesn't come out, check $LOG_DIR/bridge.log and see README.md > Troubleshooting."
