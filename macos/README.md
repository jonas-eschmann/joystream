# macOS server

Standalone Swift HTTP/WebSocket server for the iPhone and browser clients.
Requires macOS 15+ and Swift 6.2+ Command Line Tools (Xcode 26+). Python is not
needed to build or run it; the first build downloads pinned Swift packages.

**Live gamepad output requires an Apple-approved Virtual HID profile and
Accessibility permission. Device creation remains unverified on this Mac
pending that profile; networking and report generation are tested.**

## Setup

Request [Virtual HID access](https://developer.apple.com/contact/request/system-extension/)
for your Apple Developer team. Create an explicit macOS App ID and download a
macOS App Development profile covering this Mac and your certificate, with
`com.apple.developer.hid.virtual.device = true`. Ordinary iOS profiles, `sudo`,
and ad-hoc signing cannot grant this entitlement.

From the repository root:

```sh
security find-identity -v -p codesigning
./macos/run.sh build \
  --profile ~/Downloads/JoystreamServer.provisionprofile \
  --identity 'Apple Development: Your Name (XXXXXXXXXX)'
```

Enable `macos/.build/JoystreamServer.app` in **System Settings > Privacy &
Security > Accessibility**. Use Cmd+Shift+G in the picker to enter its full path.

```sh
./macos/run.sh check             # create/remove a neutral gamepad
./macos/run.sh                   # serve on 0.0.0.0:8000
./macos/run.sh run --port 9000    # also accepts --host ADDRESS
```

Open a printed address on the phone; allow incoming/Local Network connections.
Ctrl+C stops the server. The bundle includes the browser page and dependencies.
For another location, build with `--output PATH.app`, grant that copy
Accessibility, and set `JOYSTREAM_MACOS_APP=PATH.app` when running the script.
You can also run `PATH.app/Contents/MacOS/JoystreamServer` directly. Keep the
signed bundle intact; these instructions cover local development.

## Verify and develop

Run `xcrun swift macos/verify.swift` alongside the server to observe gamepad
input for 15 seconds. Both sticks and A/B/X/Y, L1/R1, Select/Start are supported;
rumble and other controls are absent. Xbox-compatible reports derive from
WaveBird; see [notices](THIRD_PARTY_NOTICES.md).

A new client takes over. Disconnects and 0.5 seconds without valid input release
controls; malformed traffic cannot extend that deadline. Output errors stop the
server. For network testing without a virtual gamepad:

```sh
./macos/run.sh build --unsigned
./macos/run.sh diagnostics --host 127.0.0.1 --port 8000
uv run --no-project --with websockets python -m unittest discover -s tests -v
```

Diagnostics prints HID reports; Python is only the integration-test client.
