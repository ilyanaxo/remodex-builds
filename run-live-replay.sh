#!/usr/bin/env bash
set -euo pipefail

source_sha="${1:?Expected application commit}"
result_dir="${2:?Output directory}"
tooling_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_dir="$tooling_dir/source"
derived_dir="$RUNNER_TEMP/remodex-live-replay-build"
device_id=""
launcher_pid=""
cleanup() {
  if [[ -n "$launcher_pid" ]]; then
    kill "$launcher_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$device_id" ]]; then
    xcrun simctl shutdown "$device_id" >/dev/null 2>&1 || true
    xcrun simctl delete "$device_id" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

cd "$source_dir"
bash CodexMobile/scripts/check-source-revision.sh "$source_sha"
xcodebuild -version
echo "Compiling the isolated iOS application without executing Xcode tests." >&3
xcodebuild -project "$source_dir/CodexMobile/CodexMobile.xcodeproj" \
  -scheme CodexMobile -configuration Release \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath "$derived_dir" build ARCHS=arm64 \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) REMODEX_PERFORMANCE_TESTING' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

xcrun simctl list runtimes --json > "$RUNNER_TEMP/remodex-replay-runtimes.json"
xcrun simctl list devicetypes --json > "$RUNNER_TEMP/remodex-replay-devices.json"
python3 - "$RUNNER_TEMP" <<'PY'
import json
from pathlib import Path
import re
import sys
root = Path(sys.argv[1])
runtimes = json.loads((root / "remodex-replay-runtimes.json").read_text())["runtimes"]
runtimes = [x for x in runtimes if x.get("isAvailable") and ".iOS-" in x["identifier"]]
assert runtimes, "No available iOS simulator runtime"
runtime = max(runtimes, key=lambda x: tuple(map(int, re.findall(r"\d+", x["version"]))))
devices = json.loads((root / "remodex-replay-devices.json").read_text())["devicetypes"]
devices = [x for x in devices if x.get("productFamily") == "iPhone"]
assert devices, "No iPhone simulator device type"
device = next((x for x in devices if x["name"] == "iPhone 16 Pro"), devices[-1])
(root / "remodex-replay-runtime-id").write_text(runtime["identifier"])
(root / "remodex-replay-device-type").write_text(device["identifier"])
PY
device_id="$(xcrun simctl create "Remodex live replay ${source_sha:0:7}" \
  "$(cat "$RUNNER_TEMP/remodex-replay-device-type")" \
  "$(cat "$RUNNER_TEMP/remodex-replay-runtime-id")")"
xcrun simctl boot "$device_id"
xcrun simctl bootstatus "$device_id" -b
app_path="$derived_dir/Build/Products/Release-iphonesimulator/CodexMobile.app"
test -d "$app_path"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Info.plist")"
xcrun simctl install "$device_id" "$app_path"
app_data="$(xcrun simctl get_app_container "$device_id" "$bundle_id" data)"
for variant in baseline stable-indicator; do
  echo "Launching isolated application replay: $variant." >&3
  replay_args=(-RemodexLiveReplay)
  if [[ "$variant" == "stable-indicator" ]]; then
    replay_args+=(-RemodexLiveReplayStableIndicator)
  fi
  rm -f "$app_data/Documents/remodex-live-replay-diagnostic.json"
  SIMCTL_CHILD_REMODEX_PROBE_SOURCE_SHA="$source_sha" \
  SIMCTL_CHILD_REMODEX_SOURCE_SHA="$source_sha" \
  xcrun simctl launch --console --terminate-running-process "$device_id" "$bundle_id" \
    "${replay_args[@]}" > "$result_dir/$variant-console.log" 2>&1 &
  launcher_pid=$!
  python3 - "$app_data" "$result_dir" "$variant" <<'PY'
from pathlib import Path
import shutil
import sys
import time
root, result = map(Path, sys.argv[1:3])
variant = sys.argv[3]
deadline = time.monotonic() + 90
while time.monotonic() < deadline:
    candidates = list((root / "Documents").glob("*live*replay*.json"))
    if candidates:
        for candidate in candidates:
            shutil.copyfile(candidate, result / (variant + ".json"))
        break
    time.sleep(1)
else:
    raise SystemExit("The application did not emit its bounded replay result")
PY
  sleep 3
  xcrun simctl io "$device_id" screenshot "$result_dir/$variant.png"
  sleep 5
  xcrun simctl io "$device_id" screenshot "$result_dir/$variant-late.png"
  xcrun simctl terminate "$device_id" "$bundle_id"
  wait "$launcher_pid" || true
  launcher_pid=""
done
bash CodexMobile/scripts/check-source-revision.sh "$source_sha"
