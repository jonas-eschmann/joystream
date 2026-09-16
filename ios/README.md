# iPhone client

Native landscape controls for either [joystream server](../README.md). Requires
iOS 16+, Xcode 15+ with an SDK compatible with your phone, and XcodeGen.

## Install

```sh
brew install xcodegen
```

One-time setup: open Xcode, finish component installation, and sign in under
**Settings > Apple Accounts**. A free Apple Account works. Connect and unlock
the iPhone over USB, accept **Trust This Computer**, then enable **Settings >
Privacy & Security > Developer Mode** and restart. If missing, pair in Xcode's
Devices window first.

From the repository root:

```sh
./ios/run.sh                             # build, sign, install, launch
./ios/run.sh devices                     # list phones
TEAM_ID=ABCDE12345 DEVICE_ID='My iPhone' ./ios/run.sh
```

Subsequent installs need no Xcode editor. `DEVICE_ID` accepts a name or UDID;
`BUNDLE_ID` overrides the default. Keep team/bundle IDs stable to preserve saved
settings. Approve signing-key access or developer-profile trust if prompted.
Refresh rejected account logins in Xcode Settings. Free profiles expire after
seven days; rerun the installer.

## Use and test

Start the server, enter an address such as `192.168.1.10:8000`, and allow
**Local Network** access. The app remembers it and reconnects automatically;
tap the bottom status to change it. Drag either half for sticks and hold buttons
simultaneously. Backgrounding or disconnecting releases controls.

```sh
./ios/run.sh simulator   # no signing account needed
./ios/run.sh test        # protocol and connection tests
./ios/run.sh build       # signed device app only
```

Install simulator runtimes in Xcode **Settings > Components**; select one with
`SIMULATOR_ID`. Missing-platform errors: `xcodebuild -downloadPlatform iOS`.
The script can fall back to an installed SDK; device installs then require an
already registered phone. Edit `project.yml`; generated projects/builds are ignored.
