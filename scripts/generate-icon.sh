#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/icon-generator
swiftc -parse-as-library scripts/generate-icon.swift -o .build/icon-generator/generate-icon
.build/icon-generator/generate-icon assets/icon.png .build/Stampede.iconset
iconutil -c icns .build/Stampede.iconset -o Resources/Stampede.icns
