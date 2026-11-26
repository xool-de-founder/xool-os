#!/bin/bash
# scripts/shoot-seq.sh NAME "dark" [SLOW] [FRAMES]
# A picture sequence of the agents panel opening and closing, from the real
# window (screencapture -l, so it is right with other windows in the way).
# The flight is played SLOW times slower (default 6) so a few frames per
# second catch it; frames are NAME-NN.png in docs/shots.
set -euo pipefail
cd "$(dirname "$0")/.."
SLOW="${3:-6}"
FRAMES="${4:-14}"
pkill -x XoolOS 2>/dev/null || true
sleep 1
P="$HOME/Library/Application Support/Xool (shots)"
mkdir -p "$P"
find "$P" -mindepth 1 -maxdepth 1 ! -name agents -exec rm -rf {} +
rm -f "$P/agents/threads.json"
mkdir -p docs/shots
T0=$(date +%s)
open -n --env XOOL_PROFILE=shots --env XOOL_FLIGHT_SLOW="$SLOW" --env XOOL_UI="$2,agentstoggle:8,agentstoggle:$((8 + SLOW * 6 / 10 + 2))" "$PWD/build/Xool OS.app"
sleep 3
ID=$(swift - <<'SW'
import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String:Any]]
var best = (0, 0.0)
for w in l where (w["kCGWindowOwnerName"] as? String ?? "") == "XoolOS" || (w["kCGWindowOwnerName"] as? String ?? "") == "Xool OS" {
    let b = w["kCGWindowBounds"] as! [String: Double]
    let a = (b["Width"] ?? 0) * (b["Height"] ?? 0)
    if a > best.1 { best = (w["kCGWindowNumber"] as! Int, a) }
}
print(best.0)
SW
)
sleep 2
n=0
while [ $n -lt "$FRAMES" ]; do
  n=$((n+1))
  screencapture -x -o -l "$ID" "docs/shots/$1-$(printf %02d $n).png"
  echo "frame $n at $(( $(date +%s) - T0 )) s"
done
echo "$n frames: docs/shots/$1-NN.png"
