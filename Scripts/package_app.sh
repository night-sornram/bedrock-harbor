#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/out/Products/Debug/BedrockHarbor"
APP="${1:-/Applications/BedrockHarbor.app}"
ID="com.bedrockharbor.app"
ASSETS="$ROOT/Assets"

swift build --package-path "$ROOT"
test -x "$BIN"

mkdir -p "$ASSETS"
if [ -n "${SRC_LOGO:-}" ] && [ -f "$SRC_LOGO" ]; then
  cp -f "$SRC_LOGO" "$ASSETS/BedrockHarbor.png"
fi
LOGO="$ASSETS/BedrockHarbor.png"
test -f "$LOGO"

# Build AppIcon.icns from the logo
ICONSET="$ASSETS/AppIcon.iconset"
ICNS="$ASSETS/AppIcon.icns"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 64 128 256 512 1024; do
  sips -z $size $size "$LOGO" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  if [ $double -le 1024 ]; then
    sips -z $double $double "$LOGO" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  fi
done
iconutil -c icns "$ICONSET" -o "$ICNS"
rm -rf "$ICONSET"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BedrockHarbor"
chmod 755 "$APP/Contents/MacOS/BedrockHarbor"
# SwiftPM resource bundles — Bundle.module lookups crash the packaged app without them
find "$ROOT/.build/out/Products/Debug" -maxdepth 1 -name "*_*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;
cp "$LOGO" "$APP/Contents/Resources/BedrockHarbor.png"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>BedrockHarbor</string>
  <key>CFBundleIdentifier</key><string>${ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>BedrockHarbor</string>
  <key>CFBundleDisplayName</key><string>BedrockHarbor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier "$ID" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
touch "$APP"
# Refresh Finder/Dock icon
killall Dock 2>/dev/null || true
killall Finder 2>/dev/null || true

echo "Installed $APP (icon: AppIcon.icns + cover: BedrockHarbor.png)"
ls -la "$APP/Contents/Resources"
