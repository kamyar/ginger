#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$PWD/build/Ginger.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Ginger" "$APP/Contents/MacOS/Ginger"
cp packaging/Info.plist "$APP/Contents/Info.plist"
# Remove bundled widgets from older builds. Scripts are installed separately.
rm -rf "$APP/Contents/Resources/defaults"
# Remove profiles from older WeatherKit builds. No provisioning profile is needed.
rm -f "$APP/Contents/embedded.provisionprofile"
/usr/bin/codesign --force --sign "${SIGNING_IDENTITY:--}" "$APP"
/usr/bin/codesign --verify --strict "$APP"
printf 'Built %s\n' "$APP"
