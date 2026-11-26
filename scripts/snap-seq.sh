#!/bin/bash
# scripts/snap-seq.sh NAME "dark,..." TOGGLE_AT "t1 t2 t3 …"
# A picture sequence of the agents panel's opening: the window draws itself to
# docs/shots/NAME-<n>.png at each time (seconds after launch); the overview is
# toggled at TOGGLE_AT. Works with the screen asleep or locked (see snap-state.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
pkill -x XoolOS 2>/dev/null || true
sleep 1
P="$HOME/Library/Application Support/Xool (shots)"
mkdir -p "$P"
find "$P" -mindepth 1 -maxdepth 1 ! -name agents -exec rm -rf {} +
rm -f "$P/agents/threads.json"
mkdir -p docs/shots
UI="$2,agentstoggle:$3"
n=0
for t in $4; do
  n=$((n+1))
  UI="$UI,snapshot:$t|$PWD/docs/shots/$1-$n.png"
done
open -n --env XOOL_PROFILE=shots --env XOOL_UI="$UI" "$PWD/build/Xool OS.app"
last=$(echo $4 | awk '{print $NF}')
sleep "$(printf '%.0f' "$(echo "$last + 3" | bc)")"
