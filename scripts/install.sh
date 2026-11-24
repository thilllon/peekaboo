#!/usr/bin/env bash
# Install Peekaboo.app into ~/Applications (override with DEST=...) and register it with LaunchServices.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Peekaboo.app"
[[ -d "$APP" ]] || "$ROOT/scripts/build-app.sh"
DEST="${DEST:-$HOME/Applications}"
mkdir -p "$DEST"
rm -rf "$DEST/Peekaboo.app"
ditto "$APP" "$DEST/Peekaboo.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/Peekaboo.app"
echo "Installed: $DEST/Peekaboo.app"
