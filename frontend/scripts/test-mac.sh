#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Pass a simulator UDID as argument 1, or use any available iPhone simulator.
if [[ -n "${1:-}" ]]; then
  SIMULATOR_ID="$1"
else
  SIMULATOR_ID="$(xcrun simctl list devices available -j | python3 -c '
import json,sys
data=json.load(sys.stdin)
phones=[d for devices in data["devices"].values() for d in devices if "iPhone" in d["name"] and d.get("isAvailable")]
if not phones: sys.exit("No iPhone simulator installed. Install an iOS runtime in Xcode Settings > Components.")
print(next((d["udid"] for d in phones if d["state"] == "Booted"), phones[0]["udid"]))')"
fi

plutil -lint MovementForest.xcodeproj/project.pbxproj MovementForest/Configuration/Info.plist MovementForest/Configuration/MovementForest.entitlements
python3 scripts/validate_frontend.py --allow-local-project-settings
xcodebuild -project MovementForest.xcodeproj -scheme MovementForest \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test
xcodebuild -project MovementForest.xcodeproj -scheme MovementForest -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
