#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
destination="$HOME/Applications/Stampede.app"
refuse_existing() {
    printf 'An installation already exists at %s. Quit Stampede and back it up before replacing it.\n' "$destination" >&2
    exit 1
}
if [ -e "$destination" ] || [ -L "$destination" ]; then
    refuse_existing
fi
./scripts/build-app.sh
mkdir -p "$HOME/Applications"
# Claim the destination atomically; something may have appeared there during the build.
mkdir "$destination" 2>/dev/null || refuse_existing
ditto build/Stampede.app "$destination"
open "$destination"
