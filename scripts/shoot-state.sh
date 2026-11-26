#!/bin/bash
# scripts/shoot-state.sh NAME "dark,thread:1,..." [SECONDS]
# Opens Xool OS in its own profile ("Xool (shots)"), puts the interface in the
# requested state (see XoolUI.applyLaunchRequest), saves docs/shots/NAME.png.
set -euo pipefail
cd "$(dirname "$0")/.."
pkill -x XoolOS 2>/dev/null || true
sleep 1
# A clean profile every time: no session, history or pins in a screenshot.
P="$HOME/Library/Application Support/Xool (shots)"
mkdir -p "$P"
find "$P" -mindepth 1 -maxdepth 1 ! -name agents -exec rm -rf {} +
rm -f "$P/agents/threads.json"
open -n --env XOOL_PROFILE=shots --env XOOL_UI="$2" "$PWD/build/Xool OS.app"
sleep "${3:-6}"
scripts/shot.sh "$1"
