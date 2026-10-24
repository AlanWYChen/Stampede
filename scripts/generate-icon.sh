#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/icon-generator
swiftc -parse-as-library scripts/generate-icon.swift -o .build/icon-generator/generate-icon
# Remove generated sizes from previous runs before rebuilding the complete icon set.
rm -rf .build/Stampede.iconset
.build/icon-generator/generate-icon assets/icon.png .build/Stampede.iconset
iconutil -c icns .build/Stampede.iconset -o Resources/Stampede.icns
