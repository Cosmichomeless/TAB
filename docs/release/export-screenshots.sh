#!/bin/sh
# Regenerates docs/release/screenshots/ by running the UI walkthrough on a simulator.
# Usage: docs/release/export-screenshots.sh [simulator name]   (default: iPhone 17 Pro)
set -eu

cd "$(dirname "$0")/../.."
device="${1:-iPhone 17 Pro}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

xcodegen generate >/dev/null
# Default text size, so titles are not truncated by an accessibility setting left on the simulator.
xcrun simctl ui "$(xcrun simctl list devices available | grep -m1 "$device" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')" content_size large || true

xcodebuild test -project TAB.xcodeproj -scheme TAB -destination "platform=iOS Simulator,name=$device" \
    -only-testing:TABUITests -resultBundlePath "$work/ui.xcresult" -derivedDataPath "$work/dd" | tail -3
xcrun xcresulttool export attachments --path "$work/ui.xcresult" --output-path "$work/shots" >/dev/null

rm -f docs/release/screenshots/*.png
python3 -I - "$work/shots" docs/release/screenshots <<'PY'
import json, re, shutil, sys
src, dst = sys.argv[1:]
for test in json.load(open(f"{src}/manifest.json")):
    for a in test["attachments"]:
        name = re.sub(r"_\d+_[0-9A-F-]{36}\.png$", ".png", a["suggestedHumanReadableName"])
        shutil.copy(f"{src}/{a['exportedFileName']}", f"{dst}/{name}")
PY
ls docs/release/screenshots
