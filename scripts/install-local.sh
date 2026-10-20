#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
destination="$HOME/Applications/Stampede.app"
if [ -e "$destination" ]; then
    printf 'An installation already exists at %s. Quit Stampede and back it up before replacing it.\n' "$destination" >&2
    exit 1
fi
./scripts/build-app.sh
mkdir -p "$HOME/Applications"
ditto build/Stampede.app "$destination"
open "$destination"
