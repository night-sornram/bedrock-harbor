#!/bin/zsh
# Install a self-contained mcpelauncher runtime into BedrockHarbor only.
# Source: minecraft-linux/macos-builder — NOT hugonote/tap/mcpelauncher-swift.
set -euo pipefail

SUPPORT="$HOME/Library/Application Support/BedrockHarbor"
DL="$SUPPORT/Runtimes/_downloads"
DMG="$DL/Minecraft.Bedrock.Launcher.dmg"
MNT="$DL/mnt"
DEST="$SUPPORT/Runtimes/harbor-mcpelauncher-v1.8.4-573"
URL="https://github.com/minecraft-linux/macos-builder/releases/download/v1.8.4-573/Minecraft.Bedrock.Launcher.dmg"

mkdir -p "$DL"
if [ ! -f "$DMG" ]; then
  curl -L --fail --retry 3 -o "$DMG" "$URL"
fi
mkdir -p "$MNT"
if [ ! -d "$MNT/Minecraft Bedrock Launcher.app" ]; then
  hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MNT" >/dev/null
fi

APP="$MNT/Minecraft Bedrock Launcher.app/Contents"
rm -rf "$DEST"
mkdir -p "$DEST/MacOS" "$DEST/Resources" "$DEST/Frameworks" "$DEST/share"
cp -a "$APP/MacOS/." "$DEST/MacOS/"
cp -a "$APP/Resources/." "$DEST/Resources/"
cp -a "$APP/Frameworks/." "$DEST/Frameworks/"
cp -a "$DEST/Resources/mcpelauncher" "$DEST/share/mcpelauncher"
cat > "$DEST/runtime.json" <<EOF
{
  "version" : "v1.8.4-573",
  "source" : "minecraft-linux/macos-builder",
  "sourceURL" : "$URL",
  "deployedBy" : "BedrockHarbor isolated install"
}
EOF
echo "Runtime: $DEST"
shasum -a 256 "$DEST/MacOS/mcpelauncher-client"
hdiutil detach "$MNT" 2>/dev/null || true
