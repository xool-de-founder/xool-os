#!/bin/bash
# scripts/snap-state.sh NAME "dark,brain,..." [SECONDS]
# As shoot-state.sh, but the window draws itself to docs/shots/NAME.png
# (XOOL_UI=snapshot:…): works with the screen asleep or locked.
set -euo pipefail
cd "$(dirname "$0")/.."
pkill -x XoolOS 2>/dev/null || true
sleep 1
P="$HOME/Library/Application Support/Xool (shots)"
mkdir -p "$P"
find "$P" -mindepth 1 -maxdepth 1 ! -name agents -exec rm -rf {} +
rm -f "$P/agents/threads.json"
mkdir -p docs/shots
open -n --env XOOL_PROFILE=shots --env XOOL_UI="$2,snapshot:${3:-8}|$PWD/docs/shots/$1.png" "$PWD/build/Xool OS.app"
sleep "$(( ${3:-8} + 2 ))"
echo "docs/shots/$1.png"
