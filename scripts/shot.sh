#!/bin/bash
# Screenshot of the largest on-screen Xool OS window only: scripts/shot.sh NAME
set -euo pipefail
cd "$(dirname "$0")/.."
ID=$(swift - <<'SW'
import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String:Any]]
var best = (0, 0.0)
for w in l where (w["kCGWindowOwnerName"] as? String ?? "") == "Xool OS" || (w["kCGWindowOwnerName"] as? String ?? "") == "XoolOS" {
    let b = w["kCGWindowBounds"] as! [String: Double]
    let a = (b["Width"] ?? 0) * (b["Height"] ?? 0)
    if a > best.1 { best = (w["kCGWindowNumber"] as! Int, a) }
}
print(best.0)
SW
)
OUT="${SHOTS_DIR:-docs/shots}"; mkdir -p "$OUT"
screencapture -x -o -l "$ID" "$OUT/$1.png"
echo "$OUT/$1.png"
