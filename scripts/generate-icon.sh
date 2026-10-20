#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/icon-generator
swiftc -parse-as-library Sources/Stampede/StampIcon.swift scripts/generate-icon.swift -o .build/icon-generator/generate-icon
.build/icon-generator/generate-icon .build/Stampede.iconset
iconutil -c icns .build/Stampede.iconset -o Resources/Stampede.icns
