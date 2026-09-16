# joystream

Turn a phone into a gamepad using the [iPhone app](ios/README.md) or a browser.
Linux uses a single-file Python server and `/dev/uinput`; macOS uses a standalone
[Swift server](macos/README.md). Both serve HTTP and WebSockets on port 8000.

## Embed in Python

`pip install .` installs the receiver with only `websockets`. It serves the same
browser page and accepts the iPhone app directly, without a system gamepad,
Swift server, or HID entitlement:

```python
from joystream_input import Receiver

with Receiver(port=8000) as pad:
    # Inside your application's existing loop:
    state = pad.read()  # nonblocking; e.g. state.lx, state.a
```

`state.connected` means input is fresh; silence/disconnect returns neutral after
at most 0.5 seconds. Applications decide how to handle lost input. See
[polling](examples/read_input.py) and [cfclient adapter](examples/cfclient_reader.py)
examples. For a pip-installed Linux system gamepad, use `pip install '.[linux]'`.

## Setup and run

On Linux, install dependencies and load uinput:

```sh
sudo apt install python3-websockets python3-evdev  # or: pip install -r requirements.txt
sudo modprobe uinput
```

Your user needs write access to `/dev/uinput`. If it belongs to the `input`
group, use `sudo usermod -aG input "$USER"`, then log out and back in.
On macOS, complete the [signing and Accessibility setup](macos/README.md) first.

```sh
python3 joystream.py                     # Linux
./macos/run.sh                           # macOS
# Custom address: --host ADDRESS --port PORT (macOS: ./macos/run.sh run ...)
```

Open the printed `http://` address on the phone, or enter it in the iPhone app.
Both devices must be reachable over Wi-Fi or Tailscale; allow incoming/local
network connections when prompted. Keep the `http://` prefix in browser URLs.

## Play

Hold the phone in landscape. Touch and drag on either half to position its
stick; buttons work simultaneously. Safari's **Add to Home Screen** gives a
fullscreen client. Keep Auto-Lock off when playing in the browser; the native
app keeps the screen awake. Tap the app's status label to change servers.

One phone controls the gamepad at a time; a new connection replaces the old one.
Disconnects or 0.5 seconds of silence release controls. The device persists
across client reconnects. Verify input with `evtest` on Linux or
`xcrun swift macos/verify.swift` on macOS.

## Protocol and development

Send full JSON snapshots to `/ws`, including a heartbeat every 100 ms:

```json
{"lx":0,"ly":-0.5,"rx":0,"ry":0,"a":1,"b":0,"x":0,"y":0,"l1":0,"r1":0,"select":0,"start":0}
```

Axes range from −1 to 1, with Y positive downward; buttons are 0/1. Missing
fields mean neutral. Edit `index.html` for browser controls, `joystream.py` for
Linux mappings, or `macos/Reports.swift` for macOS reports. See the platform
READMEs for build and test commands.
