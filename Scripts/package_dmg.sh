#!/bin/zsh
# Package BedrockHarbor as a drag-to-install DMG for distribution.
# Usage: package_dmg.sh [output.dmg]   (default: Dist/BedrockHarbor-<version>.dmg)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="0.1.0"
OUT="${1:-$ROOT/Dist/BedrockHarbor-$VERSION.dmg}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Build the app into staging (not /Applications) — package_app.sh takes the target path.
bash "$ROOT/Scripts/package_app.sh" "$STAGE/approot/BedrockHarbor.app"

# Classic DMG layout: the app next to an Applications symlink for drag-install.
mv "$STAGE/approot/BedrockHarbor.app" "$STAGE/BedrockHarbor.app"
rmdir "$STAGE/approot"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
hdiutil create -volname "BedrockHarbor" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
hdiutil verify "$OUT" >/dev/null

echo "DMG ready: $OUT"
du -h "$OUT" | cut -f1
