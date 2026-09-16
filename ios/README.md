# Native iPhone client

A small UIKit app for the existing joystream server. No web view, third-party
runtime dependencies, or server changes. Requires iOS 16 or later.

## Install from the terminal

On a Mac, install Xcode 15 or newer (with an iOS SDK compatible with your phone)
and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
```

Apple requires a little one-time setup:

1. Open Xcode once, finish any component installation, and sign in under
   **Xcode > Settings > Apple Accounts** (called **Accounts** in older versions).
   A free Apple Account works; paid membership is optional.
2. Connect the iPhone over USB, unlock it, and accept **Trust This Computer**.
3. Enable **Settings > Privacy & Security > Developer Mode** on the phone,
   restart, and confirm. If the switch is missing, pair the phone in Xcode's
   Device Hub / Devices and Simulators window first.

Then, from the repository root:

```sh
./ios/run.sh
```

The script detects your team and iPhone, generates the Xcode project, builds
with automatic signing, installs using `devicectl`, and launches the app.
Subsequent changes use the same command; Xcode's editor can stay closed.
The first signed build may ask for access to your signing key in Keychain.
If iOS asks to trust your developer profile, do so in
**Settings > General > VPN & Device Management**.

If you have several teams or phones, choose explicitly:

```sh
./ios/run.sh devices
TEAM_ID=ABCDE12345 DEVICE_ID='My iPhone' ./ios/run.sh
```

`DEVICE_ID` accepts the phone's name, hardware UDID, or CoreDevice identifier.
`TEAM_ID` is your 10-character development team ID. The default bundle ID is
`local.joystream.<TEAM_ID>.client`; override with `BUNDLE_ID` if necessary. Keep
using the same team and bundle ID to update the installed app and retain its
saved server address.

Team detection reads Xcode's account preferences. If it cannot determine a
single team, set `TEAM_ID` explicitly. Automatic signing uses the Apple Account
already signed into Xcode to create provisioning profiles and register the
selected device if needed.

If signing reports that the saved login was rejected, refresh the Apple Account
in Xcode Settings, then rerun the command.

Free Personal Team profiles expire after seven days; run the install command
again to rebuild and reinstall. See Apple's
[account overview](https://developer.apple.com/help/account/basics/about-your-developer-account)
and [Developer Mode setup](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).

## Play

1. Start `python3 joystream.py` on Linux or `./macos/run.sh` on macOS. See the
   [main README](../README.md) for Linux permissions or the standalone macOS
   server setup.
2. Open joystream on the phone and enter the server's address, for example
   `192.168.1.10:8000` or `http://192.168.1.10:8000`.
3. Allow **Local Network** access when iOS asks. Hold the phone in landscape.

The app remembers the address and reconnects automatically. Tap the status
at the bottom to change servers. You can use a LAN IP, `.local` name, or
Tailscale IP. A bare host defaults to port 8000 and `/ws`. Explicit `ws://`
URLs also work; `https://` and `wss://` use TLS for a separately configured
secure proxy (both included servers use plain WebSockets).

Touch anywhere on the left or right half to place that stick's center, then
drag. A/B/X/Y, L1/R1, Select, and Start can be held alongside both sticks.
The screen stays awake while connected, and iOS's home indicator hides
automatically. There are no browser zoom or scroll gestures.

Full state is sent on changes and every 100 ms while connected. Held controls
reset on interruption, server changes, disconnect, and rotation. Backgrounding
the app closes the connection so the server releases all inputs; its existing
0.5-second silence failsafe remains in effect. Returning to the app reconnects
with neutral inputs. Opening the server editor disconnects until it is closed.

If connection attempts fail, check the server address/port, same-network
reachability, the computer's firewall, and the app's Local Network permission in iOS
Settings. Only one client can control a server at a time.

## Build and test without a phone

```sh
./ios/run.sh simulator    # build, install, open Simulator, launch; no account needed
./ios/run.sh test         # protocol, URL parsing, real WebSocket heartbeat/reconnect tests
./ios/run.sh build        # signed device .app without installing
```

Install an iOS simulator runtime in Xcode's **Settings > Components** if needed.
Use `SIMULATOR_ID=<UDID>` to select a particular simulator. The script prefers
an already booted iPhone, otherwise the first available iPhone simulator.

If Xcode reports that its latest iOS platform is missing despite an installed
SDK, the script falls back to a direct target build and can use an older
installed simulator. Physical installs in this fallback require the phone to
already be registered with your development team. To restore normal destination
selection and automatic device registration, install the platform from the CLI
with `xcodebuild -downloadPlatform iOS` (requires several GB of free disk space).

The generated project (`ios/Joystream.xcodeproj`) and build products
(`ios/.build`) are ignored by Git. Edit `project.yml` to change project settings.
The app sources are in `Joystream/`, and all build/install commands are in
`run.sh`. The installer never stages or commits files.
