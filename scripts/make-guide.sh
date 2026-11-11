#!/bin/bash
# Renders docs/guide/user-guide.html to docs/Swarf-User-Guide.pdf with headless Google Chrome
# (Chrome honours the CSS @page rules used for A4 pagination and page numbers).
set -euo pipefail
cd "$(dirname "$0")/.."
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
PROFILE="$(mktemp -d)"
trap 'rm -rf "$PROFILE"' EXIT
"$CHROME" --headless=new --disable-gpu --no-first-run --user-data-dir="$PROFILE" \
  --allow-file-access-from-files --no-pdf-header-footer \
  --print-to-pdf="docs/Swarf-User-Guide.pdf" "file://$PWD/docs/guide/user-guide.html" >/dev/null 2>&1
echo "Wrote docs/Swarf-User-Guide.pdf"
