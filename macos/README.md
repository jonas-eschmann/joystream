# Standalone macOS server

`JoystreamServer.app` is a standalone Swift HTTP/WebSocket server and virtual
Xbox-compatible gamepad. The iPhone app and browser connect directly to it;
Python is used only by the separate Linux server. The app bundles the browser
page and its compiled dependencies and can run from any directory.

**Live gamepad output still requires Apple's managed Virtual HID entitlement,
a matching provisioning profile, and Accessibility permission.** This Mac has
no approved Virtual HID profile, so live device creation remains unverified.
The real network server, report encoding, input validation, takeover, and
watchdog can all be exercised with `--dry-run` without creating a gamepad.

## Build and set up

Requirements: macOS 15+, Xcode Command Line Tools with Swift 6.2+ (Xcode 26+),
and an Apple Developer Program account approved for Virtual HID. Python and an
Xcode project are not needed. The first build downloads the pinned SwiftNIO
packages; subsequent builds use the cache in `.build`.

1. Request [Virtual HID access](https://developer.apple.com/contact/request/system-extension/)
   for your developer team. Register an explicit macOS App ID such as
   `com.yourname.joystream.server` with that capability enabled. Download a
   **macOS App Development** provisioning profile covering this Mac and your
   signing certificate. Its entitlements must include
   `com.apple.developer.hid.virtual.device = true`. An existing approved helper
   profile can also be used: the builder takes the App ID from the profile.
2. Find your signing identity, then build from the repository root:

   ```sh
   security find-identity -v -p codesigning
   ./macos/run.sh build \
     --profile ~/Downloads/JoystreamServer.provisionprofile \
     --identity 'Apple Development: Your Name (XXXXXXXXXX)'
   ```

   This compiles the server, bundles `index.html`, embeds the profile, and
   signs `macos/.build/JoystreamServer.app`. It rejects expired profiles and
   missing entitlements. A failed build leaves the existing app untouched.
3. Add and enable `macos/.build/JoystreamServer.app` in **System Settings >
   Privacy & Security > Accessibility**. In the file picker, Cmd+Shift+G lets
   you enter the full path to the hidden `.build` directory.
4. Verify gamepad creation, then start the server:

   ```sh
   ./macos/run.sh check
   ./macos/run.sh                    # default: --host 0.0.0.0 --port 8000
   ```

`check` creates a neutral device and removes it again. Successful report dispatch
is required before it reports success. `sudo`, ad-hoc signing, and ordinary iOS
profiles cannot grant the [Virtual HID entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.hid.virtual.device).
See also Apple's [virtual device documentation](https://developer.apple.com/documentation/corehid/creatingvirtualdevices).

## Run

```sh
./macos/run.sh run --port 8000
```

Enter a printed address in the iPhone app, or open it in the phone's browser.
Both use the same `/ws` JSON protocol as Linux. The browser page is served at
`/` and `/index.html` on the same port. Allow incoming connections and Local
Network access if macOS asks. Stop the server with Ctrl+C.

For a stable installation location, add this option to the build command:

```sh
--output "$HOME/Applications/JoystreamServer.app"
```

Grant Accessibility to that copy, then run the bundle directly:

```sh
"$HOME/Applications/JoystreamServer.app/Contents/MacOS/JoystreamServer" --port 8000
```

Or set `JOYSTREAM_MACOS_APP="$HOME/Applications/JoystreamServer.app"` when using
`./macos/run.sh run` or `check`. No Python, source checkout, or Swift package
cache is needed to run the built app. Use its executable from the terminal to
see addresses and diagnostics. Do not modify files inside a signed bundle.

For distribution to other Macs, use the appropriate Developer ID provisioning
and notarization workflow. These build commands target local development on a
Mac included in the provisioning profile.

## Verify

With the live server running, use a second terminal and move the phone's controls:

```sh
xcrun swift macos/verify.swift
```

The probe observes Apple's GameController framework for 15 seconds and prints
controller identity and stick/button changes. You can also check in your game
or a browser Gamepad API tester. A browser tester may need focus and a button
press before it exposes the controller.

The compatibility identity is Xbox Series BLE (`045e:0b13`). The server sends
both the BLE input report for Apple's driver and the GIP report for SDL HIDAPI.
Layouts come from [WaveBird](https://github.com/murphyjt/wavebird/tree/b04a072f1b17df58965efb14a066873a0b48da2a)
under MIT; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Recognition by
macOS, individual games, and SDL versions still needs a live check with an
entitled build.

Both sticks and A/B/X/Y, L1/R1, Select/View and Start/Menu are supported.
Triggers, D-pad, Guide, stick-clicks, Share, and rumble are absent from the phone
protocol and remain neutral. Y axes on the wire are positive downward.

## Failure handling

- A new phone takes over and closes the old connection. Controls reset before
  takeover; buffered messages or disconnects from the old phone cannot change
  the new phone's state.
- A separate HID queue releases controls after 0.5 seconds without a valid
  state, checked every 100 ms. Malformed JSON, invalid values, and ping/pong
  frames cannot keep controls held. The watchdog also runs if the network
  event loop stalls.
- Disconnect, Ctrl+C, and SIGTERM release controls. Stopping the process removes
  its device. HID output failure stops the server with an error.
- WebSocket messages are limited to 4096 bytes, including fragmented messages.
  Incomplete HTTP connections time out after 5 seconds; idle WebSocket
  connections close after 10 seconds, with inputs released much earlier.
- If macOS kills an entitled build before startup (exit 137), check its
  embedded profile, certificate, and entitlement. An ad-hoc signature with
  a restricted entitlement is not a valid development signature.

## Development without entitlement approval

```sh
./macos/run.sh build --unsigned
./macos/run.sh diagnostics --host 127.0.0.1 --port 8000
```

This builds a separate `JoystreamServer-Diagnostics.app`. Diagnostics runs the
real HTTP/WebSocket server and prints HID/GIP reports to stdout instead of
creating a virtual device. The iPhone and browser can connect to it. Normal
startup and `--check` reject this build because it has no Virtual HID entitlement.

The executable also provides `--encode` (JSON lines on stdin to encoded reports)
and `--descriptor` (the HID descriptor). `--help` lists server options.

The integration tests use Python only as a test client:

```sh
uv run --no-project --with websockets python -m unittest discover -s tests -v
# Or, with websockets installed: python3 -m unittest discover -s tests -v
```

They build the diagnostic app when needed and exercise HTTP, real WebSocket
traffic, report encoding, malformed/oversized input, heartbeat, takeover,
disconnect, shutdown, and profile validation. macOS tests are skipped on Linux.

## Migrating from the Python/helper setup

Build and run `JoystreamServer.app` using the commands above. Stop the old
Python server first so port 8000 is available. Add the new app to Accessibility.
`--macos-helper` and `JOYSTREAM_MACOS_HELPER` have been removed; the Swift server
owns networking and HID output in one process. The clients and server address
format are unchanged.
