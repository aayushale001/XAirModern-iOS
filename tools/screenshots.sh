#!/bin/zsh
# Capture native device screenshots from the in-app protocol simulator.
# Usage: tools/screenshots.sh [model] [tabs...]
set -eu
cd "$(dirname "$0")/.."
MODEL=${1:-XR18}
if (( $# > 0 )); then shift; fi
if (( $# > 0 )); then
  TABS=("$@")
else
  TABS=(mixer channel effects routing scenes meters setup)
fi
IPHONE=${IPHONE:-"iPhone 17 Pro"}
IPAD=${IPAD:-"iPad Pro 13-inch (M5)"}
OS=${OS:-26.5}
APP=build/DerivedData/Build/Products/Debug-iphonesimulator/XAirModern.app
xcodebuild -project XAirModern.xcodeproj -scheme XAirModern \
  -destination "platform=iOS Simulator,name=$IPHONE,OS=$OS" \
  -derivedDataPath build/DerivedData build -quiet
mkdir -p screenshots

capture_device() {
  local name="$1" tag="$2" udid tab
  udid=$(xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, sys
version, name = sys.argv[1:]
runtime = "com.apple.CoreSimulator.SimRuntime.iOS-" + version.replace(".", "-")
devices = json.load(sys.stdin)["devices"].get(runtime, [])
matches = [device["udid"] for device in devices if device["name"] == name]
if len(matches) != 1:
    sys.exit(f"Expected one {name} simulator with iOS {version}, found {len(matches)}")
print(matches[0])
' "$OS" "$name")
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl install "$udid" "$APP"
  for tab in "${TABS[@]}"; do
    xcrun simctl launch --terminate-running-process "$udid" com.example.XAirModern \
      -simulator "$MODEL" -tab "$tab" -strip "${STRIP:-2}" >/dev/null
    sleep "${WAIT:-6}"
    xcrun simctl io "$udid" screenshot "screenshots/$tag-$tab-$MODEL.png" >/dev/null 2>&1
    print -r -- "screenshots/$tag-$tab-$MODEL.png"
  done
}

capture_device "$IPHONE" iphone &
phone_job=$!
capture_device "$IPAD" ipad &
pad_job=$!
status_code=0
wait "$phone_job" || status_code=$?
wait "$pad_job" || status_code=$?
exit "$status_code"
