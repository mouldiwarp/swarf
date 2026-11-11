#!/bin/bash
# Capture the largest on-screen window owned by process $1 into $2.
# Capturing by PID (never by title) avoids grabbing someone else's Swarf window.
WID=$(swift -e "import CoreGraphics; let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]; let ws = l.filter { (\$0[\"kCGWindowOwnerPID\"] as? Int) == $1 && (\$0[\"kCGWindowLayer\"] as? Int) == 0 }; let area = { (w: [String: Any]) -> Double in let b = w[\"kCGWindowBounds\"] as! [String: Double]; return b[\"Width\"]! * b[\"Height\"]! }; if let w = ws.max(by: { area(\$0) < area(\$1) }) { print(w[\"kCGWindowNumber\"]!) }" 2>/dev/null)
[ -n "$WID" ] && screencapture -x -o -l "$WID" "$2" && echo "captured $WID"
