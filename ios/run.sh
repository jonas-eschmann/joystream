#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

usage() {
    cat <<'EOF'
Usage: ./ios/run.sh [install|build|simulator|test|devices]

  install    Build, sign, install and launch on an iPhone (default)
  build      Build a signed iPhone app without installing
  simulator  Build, install and launch in the iPhone simulator (no signing)
  test       Run the tests in the iPhone simulator (no signing)
  devices    List physical devices and available simulators

Optional environment variables:
  TEAM_ID       Apple development team; auto-detected if Xcode has just one
  BUNDLE_ID     Unique app ID; defaults to local.joystream.<team>.client
  DEVICE_ID     iPhone name, UDID or CoreDevice ID; auto-detected if just one
  SIMULATOR_ID  Simulator UDID; defaults to a booted or first available iPhone

One-time setup: install Xcode, sign in under Xcode > Settings > Apple Accounts,
connect/unlock/trust your iPhone, enable Developer Mode, and brew install xcodegen.
EOF
}

action=${1:-install}
case "$action" in
    -h|--help|help) usage; exit 0 ;;
    install|build|simulator|test|devices) ;;
    *) usage >&2; exit 1 ;;
esac
if ! xcrun --find xcodebuild >/dev/null 2>&1 || ! xcrun --find devicectl >/dev/null 2>&1; then
    echo 'Install Xcode 15 or newer and select it: sudo xcode-select -s /Applications/Xcode.app' >&2
    exit 1
fi
if [ "$action" = devices ]; then
    xcrun devicectl list devices
    xcrun simctl list devices available
    exit 0
fi
if ! command -v xcodegen >/dev/null; then
    echo 'Install the project generator first: brew install xcodegen' >&2
    exit 1
fi
mkdir -p .build

if [ "$action" = install ]; then
    xcrun devicectl list devices --json-output .build/devices.json >/dev/null
    # Resolve both CoreDevice ID (devicectl) and hardware UDID (xcodebuild).
    python3 - "${DEVICE_ID:-}" <<'PY' > .build/selected-device
import json, sys
devices = json.load(open('.build/devices.json'))['result']['devices']
phones = [d for d in devices if d['hardwareProperties']['deviceType'] == 'iPhone']
requested = sys.argv[1]
if requested:
    phones = [d for d in phones if requested in (
        d['identifier'], d['hardwareProperties']['udid'], d['deviceProperties']['name'])]
else:
    phones = [d for d in phones if d['connectionProperties'].get('tunnelState') != 'unavailable']
if len(phones) != 1:
    sys.exit('Connect and unlock one iPhone, or set DEVICE_ID to a name/ID from ./ios/run.sh devices.')
phone = phones[0]
if phone['connectionProperties'].get('tunnelState') == 'unavailable':
    sys.exit('The selected iPhone is unavailable. Connect it by USB, unlock it, and trust this Mac.')
if phone['deviceProperties'].get('developerModeStatus') == 'disabled':
    sys.exit('Enable Settings > Privacy & Security > Developer Mode on the iPhone, then retry.')
print(phone['identifier'])
print(phone['hardwareProperties']['udid'])
PY
    device=$(sed -n '1p' .build/selected-device)
    device_udid=$(sed -n '2p' .build/selected-device)
fi

case "$action" in
    build|install)
        if [ -z "${TEAM_ID:-}" ]; then
            TEAM_ID=$(python3 - <<'PY'
import plistlib, subprocess, sys
result = subprocess.run(['defaults', 'export', 'com.apple.dt.Xcode', '-'], capture_output=True)
settings = plistlib.loads(result.stdout) if result.returncode == 0 else {}
teams = {team['teamID'] for account in settings.get('IDEProvisioningTeamByIdentifier', {}).values()
         for team in account if 'teamID' in team}
if len(teams) != 1:
    sys.exit('Set TEAM_ID to your Apple development team ID. Sign in to Xcode > Settings > Apple Accounts once first.')
print(teams.pop())
PY
            )
        fi
        bundle_id=${BUNDLE_ID:-local.joystream.$TEAM_ID.client}
        destination='generic/platform=iOS'
        if [ "$action" = install ]; then destination="platform=iOS,id=$device_udid"; fi
        signing=("DEVELOPMENT_TEAM=$TEAM_ID" -allowProvisioningUpdates)
        if [ "$action" = install ]; then signing+=(-allowProvisioningDeviceRegistration); fi
        product=Debug-iphoneos
        sdk=iphoneos
        arch=arm64
        ;;
    simulator|test)
        xcrun simctl list devices available --json > .build/simulators.json
        simulator=$(python3 - "${SIMULATOR_ID:-}" <<'PY'
import json, sys
devices = json.load(open('.build/simulators.json'))['devices']
phones = [d for runtime, group in devices.items() if '.iOS-' in runtime
          for d in group if d.get('isAvailable') and d['name'].startswith('iPhone')]
if sys.argv[1]:
    phones = [d for d in phones if d['udid'] == sys.argv[1]]
phones.sort(key=lambda d: d['state'] != 'Booted')
if not phones:
    sys.exit('No matching iPhone simulator. Install an iOS runtime in Xcode > Settings > Components.')
print(phones[0]['udid'])
PY
        )
        state=$(xcrun simctl list devices booted --json)
        if ! python3 -c 'import json,sys; sys.exit(not any(d["udid"] == sys.argv[1] for g in json.load(sys.stdin)["devices"].values() for d in g))' "$simulator" <<< "$state"; then
            xcrun simctl boot "$simulator"
        fi
        xcrun simctl bootstatus "$simulator" -b
        destination="platform=iOS Simulator,id=$simulator"
        bundle_id=${BUNDLE_ID:-local.joystream.client}
        signing=(CODE_SIGNING_ALLOWED=NO)
        product=Debug-iphonesimulator
        sdk=iphonesimulator
        arch=$(uname -m)
        ;;
esac

xcodegen generate --spec project.yml
build_action=build
if [ "$action" = test ]; then build_action=test; fi
destinations=$(xcodebuild -project Joystream.xcodeproj -scheme Joystream -showdestinations 2>&1)
if [[ "$destinations" == *"error:"*"is not installed"* ]]; then
    # Some Xcode installations reject all scheme destinations until the newest
    # simulator is downloaded, even though an SDK and an older runtime work.
    echo 'Xcode reports missing platform support; building directly with the installed SDK.'
    target=Joystream
    if [ "$action" = test ]; then target=JoystreamTests; fi
    if ! xcodebuild -quiet -project Joystream.xcodeproj -target "$target" -sdk "$sdk" \
        -configuration Debug "ARCHS=$arch" "SYMROOT=$PWD/.build/Build/Products" \
        "OBJROOT=$PWD/.build/Build/Intermediates.noindex" \
        "JOYSTREAM_BUNDLE_ID=$bundle_id" "${signing[@]}" build; then
        echo 'Build failed. For signing errors, refresh your Apple Account in Xcode Settings and check TEAM_ID/BUNDLE_ID.' >&2
        exit 1
    fi
    if [ "$action" = test ]; then
        python3 test-runner.py "$bundle_id" > .build/Build/Products/Joystream.xctestrun
        xcodebuild -quiet test-without-building -xctestrun .build/Build/Products/Joystream.xctestrun \
            -destination "$destination"
    elif [ "$action" = install ]; then
        echo 'Direct builds require this iPhone to be registered with your development team already.'
    fi
else
    if ! xcodebuild -quiet -project Joystream.xcodeproj -scheme Joystream \
        -configuration Debug -destination "$destination" -derivedDataPath .build \
        "JOYSTREAM_BUNDLE_ID=$bundle_id" "${signing[@]}" "$build_action"; then
        echo 'Build failed. For signing errors, refresh your Apple Account in Xcode Settings and check TEAM_ID/BUNDLE_ID.' >&2
        exit 1
    fi
fi
app="$PWD/.build/Build/Products/$product/Joystream.app"
case "$action" in
    install)
        xcrun devicectl device install app --device "$device" "$app"
        xcrun devicectl device process launch --device "$device" --terminate-existing "$bundle_id"
        ;;
    simulator)
        xcrun simctl install "$simulator" "$app"
        open -a Simulator
        xcrun simctl launch --terminate-running-process "$simulator" "$bundle_id"
        ;;
    build) echo "Built: $app" ;;
esac
