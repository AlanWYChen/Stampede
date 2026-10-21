#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-release}"
swift build -c "$configuration" --scratch-path .build
binary_directory="$(swift build -c "$configuration" --scratch-path .build --show-bin-path)"
app="build/Stampede.app"
rm -rf -- "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_directory/Stampede" "$app/Contents/MacOS/Stampede"
cp Resources/Stampede.icns "$app/Contents/Resources/Stampede.icns"
cp Resources/Info.plist "$app/Contents/Info.plist"
# Local build only. Use a stable developer identity for persistent Keychain trust and distribution.
codesign --force --options runtime --sign "${CODE_SIGN_IDENTITY:--}" "$app"
plutil -lint "$app/Contents/Info.plist"
codesign --verify --strict --verbose=2 "$app"
printf 'Built %s/build/Stampede.app\n' "$PWD"
