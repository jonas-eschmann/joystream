# joystream

Turn a phone's touchscreen into a Linux or macOS gamepad.

Use the [native iPhone app](ios/README.md) or the browser client. The native
app has landscape controls, keeps the screen awake while connected, and needs
no web page. Both clients work with either server:

- **Linux:** Python serves HTTP/WebSockets and writes to `/dev/uinput`.
- **macOS:** a standalone Swift app serves HTTP/WebSockets and creates a virtual
  HID gamepad. Python is not needed to build or run it.

**macOS requires an Apple-approved Virtual HID entitlement and Accessibility
permission**; see [macOS setup](macos/README.md). Live macOS gamepad creation is
still unverified on the development Mac pending an approved profile.

```text
iPhone app / browser --WebSocket--> Python server (Linux) --> uinput gamepad
                    --WebSocket--> Swift server (macOS)  --> HID gamepad
```

## Install

### Linux

Two dependencies, both packaged by most distros:

```
sudo apt install python3-websockets python3-evdev    # Debian / Ubuntu
# or
pip install -r requirements.txt                       # evdev builds a small C extension
```

You need write access to `/dev/uinput`. On Ubuntu it is `root:input 0660`, so
either add yourself to the `input` group (log out and in again):

```
sudo usermod -aG input $USER
```

or drop a udev rule for a group of your choice:

```
echo 'KERNEL=="uinput", GROUP="input", MODE="0660"' | sudo tee /etc/udev/rules.d/99-uinput.rules
sudo udevadm control --reload && sudo modprobe uinput
```

### macOS

Follow the [standalone Swift server setup](macos/README.md) to build and sign
`JoystreamServer.app` from the CLI. Requirements are macOS 15+, Swift 6.2+
Command Line Tools, and an approved Virtual HID profile. No Python environment
or Xcode project is needed.

```sh
./macos/run.sh build --profile ~/Downloads/JoystreamServer.provisionprofile \
  --identity 'Apple Development: Your Name (XXXXXXXXXX)'
# Grant JoystreamServer.app Accessibility permission, then:
./macos/run.sh check
./macos/run.sh
```

## Run

```sh
python3 joystream.py             # Linux
./macos/run.sh                   # macOS
# Both default to --port 8000 --host 0.0.0.0
```

It prints the URL to open on the phone, e.g. `http://10.0.0.5:8000`. Phone and
computer must be on the same network. Plain HTTP is fine: touch input and
websockets do not need HTTPS on iOS.

On the phone:

- Type the URL **with `http://`**. Recent iOS Safari tries `https://` first for
  addresses typed without a scheme. Both servers use plain HTTP. The
  phone must be able to reach the computer through Wi-Fi and its firewall.
  A Tailscale IP works too when both devices are on it.
- Hold it in landscape. Touch anywhere on the left half for the left stick and
  anywhere on the right half for the right stick. The stick centers where your
  finger lands, so touchdown is always neutral.
- A/B/X/Y, L1/R1, Select and Start are buttons. Two sticks and a button can be
  held at the same time.
- Safari: Share, then "Add to Home Screen". Opening it from there gives a true
  full-screen page without the address bar or the edge-swipe back gesture.
- If the page ever ends up zoomed in (iOS lets some gestures past the page's
  guards), reload it: zoom resets on load. From the Home Screen version, close
  the app from the app switcher and open it again.
- Set Auto-Lock to Never while playing. The Screen Wake Lock API needs HTTPS,
  so the page cannot keep the screen on by itself.

## Verify on the Linux side

```
evtest                      # pick "joystream", move a stick, press buttons
jstest --normal /dev/input/js0
```

Or open any browser Gamepad API tester on the Linux machine. The device uses
the standard evdev gamepad codes (`BTN_SOUTH` and friends, `ABS_X/Y/RX/RY`), so
udev tags it `ID_INPUT_JOYSTICK` and SDL2 maps it to the standard controller
layout without a mapping file.

On macOS, use `xcrun swift macos/verify.swift` while the server runs to inspect
Apple GameController input. See [macOS verification and limitations](macos/README.md#verify).

## Behaviour worth knowing

- **Failsafe.** The page sends its full state at least every 100 ms. If the
  server hears nothing for 0.5 s (Wi-Fi drop, phone locked, tab backgrounded)
  it sets every axis to zero and releases every button. Same on disconnect.
  The macOS server runs its watchdog on a separate HID queue, refreshes it only
  for valid input, and removes its device when it exits.
- **One phone at a time.** A new connection takes over and the previous one is
  closed. The virtual device itself is created once at startup and stays put
  across reconnects, so programs that bind to a joystick at launch keep
  working.
- **Protocol.** One JSON object per message, all fields optional, missing
  fields mean neutral:

  ```json
  {"lx":0.0,"ly":-0.5,"rx":0.0,"ry":0.0,"a":1,"b":0,"x":0,"y":0,"l1":0,"r1":0,"select":0,"start":0}
  ```

  Axes are -1..1 with y positive downward (the Linux convention: stick up is
  negative). Buttons are 0 or 1.

## Customising

- Add or move controls in the `STICKS` and `BUTTONS` tables at the top of the
  script in `index.html`. Positions are percentages of the screen, sizes are
  in `vmin` in the CSS.
- Add new inputs in the `BUTTONS` and `AXES` dictionaries in `joystream.py` for
  Linux, or in `macos/Reports.swift` for macOS, and update the clients to send them.
- `FAILSAFE_S` in `joystream.py` and the watchdog in `macos/HIDDevice.swift` set
  each server's silence timeout.

## Tests

```sh
uv run --no-project --with websockets python -m unittest discover -s tests -v
```

On macOS these tests build a diagnostic Swift server and exercise real HTTP and
WebSocket connections, report encoding, and the watchdog without creating a
system gamepad. Python is only a test client for the Swift server. These tests
are skipped on Linux; the original single-file Python server is unchanged.
