#!/bin/zsh
# Stages the community Google-Play-API CLI tools (gplaydl/gplayver) plus their
# Homebrew dylib dependency closure into the app bundle, so end users need no
# Homebrew. Invoked by package_app.sh before codesigning.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Vendor/Google-Play-API"
APP="${1:?usage: bundle_gplaydl.sh <BedrockHarbor.app>}"
FW="$APP/Contents/Frameworks"
BIN="$APP/Contents/MacOS"

# Incremental builds pick up helper protocol fixes even when old binaries exist.
cmake -B "$SRC/build" -S "$SRC" -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=/opt/homebrew >/dev/null
cmake --build "$SRC/build" --target gplaydl gplayver -j8
test -x "$SRC/build/gplaydl" && test -x "$SRC/build/gplayver"

mkdir -p "$FW" "$BIN"
cp -f "$SRC/build/gplaydl" "$SRC/build/gplayver" "$BIN/"

# Copy the dylib closure: start from the two binaries, keep pulling in any
# /opt/homebrew dependency until nothing new appears.
todo=("$BIN/gplaydl" "$BIN/gplayver")
while true; do
  next=()
  for f in "${todo[@]}"; do
    for dep in $(otool -L "$f" | awk '/opt\/homebrew/ {print $1}' | sort -u); do
      name="$(basename "$dep")"
      [ -e "$FW/$name" ] && continue
      cp "$dep" "$FW/$name"
      next+=("$FW/$name")
    done
  done
  [ ${#next[@]} -eq 0 ] && break
  todo=("${next[@]}")
done

# Point every homebrew reference at the bundled copy (the binaries live in
# MacOS/, the dylibs one level up in Frameworks/ — both resolve via
# @executable_path/../Frameworks from the binaries' perspective; dylibs among
# themselves resolve it relative to their own load path, which is the same dir).
for f in "$BIN/gplaydl" "$BIN/gplayver" "$FW"/*.dylib; do
  for dep in $(otool -L "$f" | awk '/opt\/homebrew/ {print $1}' | sort -u); do
    install_name_tool -change "$dep" "@loader_path/../Frameworks/$(basename "$dep")" "$f" 2>/dev/null ||
    install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$f"
  done
done
for f in "$FW"/*.dylib; do
  install_name_tool -id "@loader_path/$(basename "$f")" "$f" 2>/dev/null || true
done

xattr -dr com.apple.quarantine "$FW" "$BIN/gplaydl" "$BIN/gplayver" 2>/dev/null || true

# install_name_tool invalidates signatures — the kernel SIGKILLs unsigned
# modified binaries on exec. Re-sign everything we touched.
for f in "$BIN/gplaydl" "$BIN/gplayver" "$FW"/*.dylib; do
  codesign --force --sign - "$f" 2>/dev/null || true
done

echo "Bundled gplaydl/gplayver with $(ls "$FW" | wc -l | tr -d ' ') support dylibs"
