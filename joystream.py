#!/usr/bin/env python3
"""joystream: turn a phone's touchscreen into a Linux gamepad.

Serves index.html over HTTP and accepts gamepad state over a websocket on the
same port. Every state message is written to a virtual gamepad created through
/dev/uinput, so any Linux program sees an ordinary controller.
"""
import argparse
import asyncio
import json
import logging
import socket
import time
from pathlib import Path

from evdev import AbsInfo, InputDevice, UInput, ecodes as e, list_devices
from websockets.asyncio.server import ServerConnection, serve
from websockets.datastructures import Headers
from websockets.exceptions import ConnectionClosed, InvalidMessage
from websockets.http11 import Response

# Client state keys -> evdev codes. These are the standard gamepad codes, so
# SDL2 and friends recognise the device as a normal controller with no mapping.
BUTTONS = {
    "a": e.BTN_SOUTH, "b": e.BTN_EAST, "x": e.BTN_WEST, "y": e.BTN_NORTH,
    "l1": e.BTN_TL, "r1": e.BTN_TR,
    "select": e.BTN_SELECT, "start": e.BTN_START,
}
AXES = {"lx": e.ABS_X, "ly": e.ABS_Y, "rx": e.ABS_RX, "ry": e.ABS_RY}
AXIS_MAX = 32767
FAILSAFE_S = 0.5  # go neutral if the phone stays silent this long
PAD_NAME = "joystream"

INDEX = Path(__file__).with_name("index.html")


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


class QuietPreconnects(logging.Filter):
    """Drop websockets' traceback for TCP connections that close before sending
    an HTTP request. Safari opens speculative connections like that on every
    page load; they are harmless and would otherwise spam the terminal."""

    def filter(self, record):
        exc = record.exc_info[1] if record.exc_info else None
        return not isinstance(exc, InvalidMessage)


def make_pad():
    absinfo = AbsInfo(value=0, min=-AXIS_MAX, max=AXIS_MAX, fuzz=0, flat=0, resolution=0)
    return UInput(
        {e.EV_KEY: list(BUTTONS.values()),
         e.EV_ABS: [(code, absinfo) for code in AXES.values()]},
        name=PAD_NAME, bustype=e.BUS_VIRTUAL,
    )


def find_node(name):
    """Best-effort lookup of /dev/input/eventN for our device (needs read access)."""
    for path in list_devices():
        try:
            if InputDevice(path).name == name:
                return path
        except OSError:
            pass
    return "(node not readable, see README permissions)"


def apply(pad, state):
    """Write a full state snapshot. Missing keys mean neutral / released."""
    for key, code in AXES.items():
        v = max(-1.0, min(1.0, float(state.get(key, 0))))
        pad.write(e.EV_ABS, code, int(v * AXIS_MAX))
    for key, code in BUTTONS.items():
        pad.write(e.EV_KEY, code, 1 if state.get(key) else 0)
    pad.syn()


class Server:
    def __init__(self, pad):
        self.pad = pad
        self.client = None  # the one connection currently driving the pad

    async def handle(self, ws):
        peer = ws.remote_address[0]
        if self.client is not None:
            log(f"{peer} takes over from {self.client.remote_address[0]}")
            asyncio.ensure_future(self.client.close())
        self.client = ws
        log(f"{peer} connected")
        silent = False
        try:
            while True:
                try:
                    msg = await asyncio.wait_for(ws.recv(), FAILSAFE_S)
                except asyncio.TimeoutError:
                    if not silent:
                        log(f"{peer} silent for {FAILSAFE_S}s, pad set to neutral")
                    silent = True
                    apply(self.pad, {})
                    continue
                silent = False
                try:
                    apply(self.pad, json.loads(msg))
                except (ValueError, TypeError, AttributeError):
                    pass  # malformed message, ignore
        except ConnectionClosed:
            pass
        finally:
            if self.client is ws:
                self.client = None
                apply(self.pad, {})
            log(f"{peer} disconnected")


class PadConnection(ServerConnection):
    """Peek at the first bytes: a TLS ClientHello means the phone tried https://.
    Closing at once makes Safari fall back to http:// instead of hanging."""
    peeked = False

    def data_received(self, data):
        if not self.peeked:
            self.peeked = True
            if data[:1] == b"\x16":
                log(f"{self.remote_address[0]} tried HTTPS, open the http:// URL instead")
                self.transport.abort()
                return
        super().data_received(data)


def process_request(conn, request):
    """Answer plain HTTP GETs for the page; let /ws continue as a websocket."""
    if request.path == "/ws":
        return None
    log(f"{conn.remote_address[0]} GET {request.path} ({request.headers.get('User-Agent', '?')})")
    if request.path in ("/", "/index.html"):
        body = INDEX.read_bytes()
        return Response(200, "OK", Headers([
            ("Content-Type", "text/html; charset=utf-8"),
            ("Content-Length", str(len(body))),
            ("Connection", "close"),
        ]), body)
    return Response(404, "Not Found", Headers([("Content-Length", "0"), ("Connection", "close")]))


def lan_ip():
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.255.255.255", 1))
            return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"


async def main(host, port):
    logging.getLogger("websockets.server").addFilter(QuietPreconnects())
    pad = make_pad()
    try:
        apply(pad, {})
        await asyncio.sleep(0.2)  # let udev create the node before we look for it
        log(f"virtual gamepad created: {find_node(PAD_NAME)}")
        srv = Server(pad)
        async with serve(srv.handle, host, port, process_request=process_request,
                         create_connection=PadConnection, compression=None,
                         ping_interval=5, ping_timeout=5):
            log(f"open http://{lan_ip()}:{port} on your phone")
            await asyncio.get_running_loop().create_future()
    finally:
        pad.close()


def cli():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8000)
    args = ap.parse_args()
    try:
        asyncio.run(main(args.host, args.port))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    cli()
