#!/bin/zsh
# Import a Minecraft Bedrock game package into Harbor-owned Installations.
# Usage: Scripts/import_game_package.sh /path/to/game-dir
# game-dir must contain lib/arm64-v8a/libminecraftpe.so
set -euo pipefail

SRC="${1:-}"
if [ -z "$SRC" ] || [ ! -d "$SRC" ]; then
  echo "Usage: $0 /path/to/game-directory"
  echo "Expected: <dir>/lib/arm64-v8a/libminecraftpe.so"
  exit 1
fi
LIB="$SRC/lib/arm64-v8a/libminecraftpe.so"
if [ ! -f "$LIB" ]; then
  echo "Not a Bedrock package: missing $LIB"
  exit 1
fi

VERSION="$(basename "$SRC")"
DEST="$HOME/Library/Application Support/BedrockHarbor/Installations/$VERSION"
if [ "$SRC" -ef "$DEST" ]; then
  echo "Already at $DEST"
else
  mkdir -p "$(dirname "$DEST")"
  rm -rf "$DEST"
  cp -a "$SRC" "$DEST"
fi
chmod -R u+rwX "$DEST"
echo "Imported -> $DEST"
ls -la "$DEST/lib/arm64-v8a/libminecraftpe.so"
shasum -a 256 "$DEST/lib/arm64-v8a/libminecraftpe.so"
