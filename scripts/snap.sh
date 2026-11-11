#!/bin/bash
# Capture the first on-screen Swarf window whose title contains $1 into $2.
WID=$(swift -e "import CoreGraphics; let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]; for w in l where (w[\"kCGWindowOwnerName\"] as? String) == \"Swarf\" && (w[\"kCGWindowLayer\"] as? Int) == 0 && ((w[\"kCGWindowName\"] as? String) ?? \"\").contains(\"$1\") { print(w[\"kCGWindowNumber\"]!); break }" 2>/dev/null)
[ -n "$WID" ] && screencapture -x -o -l "$WID" "$2" && echo "captured $WID"
