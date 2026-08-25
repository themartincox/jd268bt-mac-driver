# JD-268BT Mac Bluetooth Driver

Wireless (Bluetooth) printing for the **Jadens JD-268BT** thermal label
printer on macOS.

Jadens ships a real macOS driver, but it only works over USB — there's no
supported way to print to this printer over Bluetooth on a Mac. This
project fills that one gap. It does **not** reverse-engineer Jadens'
printer protocol: it reuses their own official PPD and print filter (which
speaks the public [TSPL](https://en.wikipedia.org/wiki/TSPL) label
language) and only adds the missing piece — getting bytes from macOS to
the printer over Bluetooth.

## How it works

```
Any app's Print dialog
        │
        ▼
   CUPS (macOS's print system)
        │  using Jadens' own PPD + rastertolabel filter
        ▼
   TSPL bytes
        │
        ▼
   socket://127.0.0.1:9100  ──►  bridge.py  ──►  Bluetooth RFCOMM  ──►  printer
```

macOS has no built-in way to treat a Bluetooth Classic "Serial Port
Profile" device (which is what this printer exposes) as a CUPS printer
backend. `bridge.py` opens a Bluetooth connection to the printer directly
(via Apple's `IOBluetooth` framework) and exposes it as a plain TCP port,
so CUPS can print to it exactly like it would a network printer.

## Requirements

- macOS (tested on Apple Silicon, macOS 26)
- [Homebrew](https://brew.sh) (used to install `blueutil`, a small CLI for
  Bluetooth pairing)
- A JD-268BT, powered on and in Bluetooth range

## Install

```bash
git clone https://github.com/<you>/jd268bt-mac-driver.git
cd jd268bt-mac-driver
./install.sh
```

The installer will:
1. Install Python's `pyobjc` Bluetooth bindings and `blueutil`.
2. Find and pair the printer over Bluetooth (PIN `0000`, the JD-268BT default).
3. Install the bridge and set it to start automatically at login.
4. Download Jadens' own official driver files directly from their site and
   install them (admin password required — you'll get a normal macOS
   password prompt).
5. Register **"Jadens JD-268BT (Bluetooth)"** as a printer.

Then just print from any app and pick that printer.

## What gets installed

| What | Where |
|---|---|
| The bridge | `~/Library/Application Support/JadensBTBridge/` |
| Bridge logs | `~/Library/Logs/JadensBTBridge/bridge.log` |
| Login item | `StartJadensBridge.command` (System Settings → General → Login Items) |
| Jadens' driver files | `/Library/Printers/Jadens/` |
| CUPS printer queue | `JadensJD268BT` |

At every login, a Terminal window briefly opens to start the bridge, then
minimizes itself automatically. This is intentional and necessary — see
[Why a Terminal window](#why-a-terminal-window) below.

## Uninstall

```bash
./uninstall.sh
```

## Troubleshooting

**Nothing prints, but no error appears.** Check
`~/Library/Logs/JadensBTBridge/bridge.log`. If it shows the job being
sent successfully but nothing comes out physically, the printer's small
onboard buffer may have dropped data mid-transfer (this happens
occasionally with larger, more image-heavy labels — the printer uses a
compressed bitmap format where a single dropped byte corrupts the whole
image). Try printing again; if it happens often, try slowing things down
further by editing `CHUNK_SIZE` / `CHUNK_DELAY` at the top of `bridge.py`
(smaller/slower is more reliable, at the cost of print speed).

**"Timed out opening RFCOMM channel."** Two possible causes:
- The printer is off, asleep, or out of range — wake/power-cycle it and
  try again.
- Its Bluetooth pairing has gotten out of sync with your Mac (this
  happens most often right after a power cycle) — macOS still shows it as
  "connected", but the printer silently ignores connection attempts. Fix
  it by re-pairing from scratch:
  ```bash
  ./repair.sh
  ```

**The bridge isn't running.** Check with
`ps aux | grep bridge.py`. Restart it by double-clicking
`~/Library/Application Support/JadensBTBridge/StartJadensBridge.command`.

**Wrong label size / content cut off.** Set the page size explicitly in
the Print dialog to match your labels (defaults to 4×6").

## Why a Terminal window?

This was the hardest part to get right. macOS gates Bluetooth access
behind a permission that's tied to how a process was launched — a plain
background process (a LaunchAgent, or an app launched via `open`/
LaunchServices) reliably gets silently denied with no prompt ever shown,
even when wrapped in its own signed `.app` bundle. The only reliable fix
found was launching the bridge as a genuine child process of `Terminal.app`
itself (which already has Bluetooth access), via a `.command` file
registered as a macOS Login Item. It's not elegant, but it's what
actually works.

## License

MIT — see [LICENSE](LICENSE). This covers `bridge.py`, the install
scripts, and this README only. `install.sh` downloads Jadens' own driver
(PPD + print filter) directly from their website at install time; those
files remain Jadens' property and are not redistributed by this
repository.

## Disclaimer

Unofficial, community project. Not affiliated with or endorsed by Jadens.
