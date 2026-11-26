#!/bin/bash
# Rebuilds Resources/canvas from web/canvas/src. Needs Node 20+ (only here:
# the app's ./build.sh just copies the checked-in result).
#   web/canvas/build.sh          install exactly what package-lock.json says, then bundle
#   web/canvas/build.sh --check  type-check only
set -euo pipefail
cd "$(dirname "$0")"
command -v node >/dev/null || { echo "Node 20+ is needed to rebuild the canvas (brew install node)."; exit 1; }
[ -d node_modules ] || npm ci --no-audit --no-fund
if [ "${1:-}" = "--check" ]; then exec npx tsc --noEmit; fi
node build.mjs
