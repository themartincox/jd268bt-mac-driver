#!/usr/bin/env python3
"""Bluetooth-to-TCP bridge for Jadens Bluetooth label printers (JD-268BT etc).

macOS has no way to address a Bluetooth Classic Serial Port Profile (SPP)
device as a CUPS printer backend directly. This bridge opens a Bluetooth
RFCOMM connection to the printer and listens on 127.0.0.1:9100 (the
standard raw/JetDirect print port), relaying whatever bytes it receives
straight to the printer. CUPS (via the printer's own PPD + filter) can
then treat the printer as an ordinary `socket://` network printer.

Configuration is read from config.json next to this file (written by
install.sh): {"address": "AA-BB-CC-DD-EE-FF", "channel": 1}. If "channel"
is omitted, the RFCOMM channel for the Serial Port Profile (UUID 1101) is
discovered via SDP query each time a connection is opened.
"""
import json
import queue
import re
import socketserver
import sys
import threading
import time
from pathlib import Path

import objc
from Foundation import NSDate, NSObject, NSRunLoop
from IOBluetooth import IOBluetoothDevice

CONFIG_PATH = Path(__file__).resolve().parent / "config.json"
LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 9100
CHUNK_SIZE = 128
CHUNK_DELAY = 0.05
INITIAL_SETTLE_DELAY = 0.3
OPEN_TIMEOUT = 15
SPP_UUID_HEX = "1101"
LOG = lambda *a: print(time.strftime("%H:%M:%S"), *a, file=sys.stderr, flush=True)


def load_config():
    if not CONFIG_PATH.exists():
        LOG(f"missing {CONFIG_PATH} - run install.sh first")
        sys.exit(1)
    cfg = json.loads(CONFIG_PATH.read_text())
    if "address" not in cfg:
        LOG("config.json is missing 'address'")
        sys.exit(1)
    return cfg


class _Delegate(NSObject):
    def rfcommChannelOpenComplete_status_(self, channel, status):
        self.worker.open_status = status
        self.worker.open_event.set()

    def rfcommChannelClosed_(self, channel):
        pass

    def rfcommChannelWriteComplete_refcon_status_(self, channel, refcon, status):
        pass


class BTWorker:
    """IOBluetooth delivers its async callbacks on the main thread's run
    loop, so all Bluetooth calls (and the run loop pumping) must happen on
    the main thread. run_forever() below is meant to be called from there;
    everyone else (e.g. the TCP server thread) just calls submit()."""

    def __init__(self, address, channel_id=None):
        self.address = address
        self.fixed_channel_id = channel_id
        self.jobs = queue.Queue()
        self.open_event = threading.Event()
        self.open_status = None
        self.device = None

    def run_forever(self):
        self.device = IOBluetoothDevice.deviceWithAddressString_(self.address)
        rl = NSRunLoop.currentRunLoop()
        while True:
            try:
                data, result, done = self.jobs.get(timeout=0.1)
            except queue.Empty:
                rl.runUntilDate_(NSDate.dateWithTimeIntervalSinceNow_(0.1))
                continue
            try:
                self._send(data)
                result["ok"] = True
            except Exception as e:
                result["ok"] = False
                result["error"] = str(e)
            finally:
                done.set()

    def _discover_channel(self):
        if self.fixed_channel_id:
            return self.fixed_channel_id
        self.device.performSDPQuery_(None)
        rl = NSRunLoop.currentRunLoop()
        for _ in range(25):
            rl.runUntilDate_(NSDate.dateWithTimeIntervalSinceNow_(0.2))
        for svc in self.device.services() or []:
            desc = str(svc).replace(" ", "").lower()
            if SPP_UUID_HEX in desc:
                m = re.search(r"rfcommchannelid:(\d+)", desc)
                if m:
                    return int(m.group(1))
        LOG("could not discover SPP RFCOMM channel via SDP, defaulting to channel 1")
        return 1

    def _send(self, data):
        channel_id = self._discover_channel()
        delegate = _Delegate.alloc().init()
        delegate.worker = self
        self.open_event.clear()
        self.open_status = None

        code, channel = self.device.openRFCOMMChannelAsync_withChannelID_delegate_(
            None, channel_id, delegate
        )
        if code != 0:
            raise RuntimeError(f"open failed immediately: {code}")

        rl = NSRunLoop.currentRunLoop()
        deadline = time.time() + OPEN_TIMEOUT
        while not self.open_event.is_set() and time.time() < deadline:
            rl.runUntilDate_(NSDate.dateWithTimeIntervalSinceNow_(0.1))
        if not self.open_event.is_set():
            raise RuntimeError("timed out opening RFCOMM channel")
        if self.open_status != 0:
            raise RuntimeError(f"open failed, status {self.open_status}")

        LOG(f"channel open (ch{channel_id}), sending {len(data)} bytes")
        time.sleep(INITIAL_SETTLE_DELAY)
        for i in range(0, len(data), CHUNK_SIZE):
            chunk = data[i : i + CHUNK_SIZE]
            res = channel.writeSync_length_(chunk, len(chunk))
            if res != 0:
                raise RuntimeError(f"write failed, status {res} at offset {i}")
            time.sleep(CHUNK_DELAY)
        time.sleep(0.3)
        channel.closeChannel()
        LOG("job sent, channel closed")

    def submit(self, data, timeout=60):
        result = {}
        done = threading.Event()
        self.jobs.put((data, result, done))
        if not done.wait(timeout):
            raise TimeoutError("print job timed out")
        if not result.get("ok"):
            raise RuntimeError(result.get("error", "unknown error"))


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        chunks = []
        self.request.settimeout(30)
        try:
            while True:
                chunk = self.request.recv(65536)
                if not chunk:
                    break
                chunks.append(chunk)
        except OSError:
            pass
        data = b"".join(chunks)
        LOG(f"received job: {len(data)} bytes from {self.client_address}")
        if not data:
            return
        try:
            self.server.worker.submit(data)
        except Exception as e:
            LOG("ERROR sending to printer:", e)


class Server(socketserver.TCPServer):
    allow_reuse_address = False


def main():
    cfg = load_config()
    worker = BTWorker(cfg["address"], cfg.get("channel"))
    try:
        server = Server((LISTEN_HOST, LISTEN_PORT), Handler)
    except OSError:
        LOG(f"port {LISTEN_PORT} already in use - bridge is likely already running, exiting")
        return
    server.worker = worker
    LOG(f"Jadens BT bridge listening on {LISTEN_HOST}:{LISTEN_PORT} -> {cfg['address']}")
    threading.Thread(target=server.serve_forever, daemon=True).start()
    worker.run_forever()  # must run on the main thread


if __name__ == "__main__":
    main()
