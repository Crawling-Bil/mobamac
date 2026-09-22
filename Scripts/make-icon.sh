#!/bin/bash
# Scripts/make-icon.sh
#
# Converts a square PNG (1024x1024 recommended) into Assets/AppIcon.icns,
# using only tools built into macOS (sips + iconutil).
#
# Usage (from anywhere):
#   Scripts/make-icon.sh Assets/logo.png

set -e

SOURCE="$1"
if [ -z "$SOURCE" ]; then
    echo "Usage: Scripts/make-icon.sh path/to/logo.png"
    exit 1
fi
if [ ! -f "$SOURCE" ]; then
    echo "File not found: $SOURCE"
    exit 1
fi
# Resolve the source before changing directory, so relative paths still work.
SOURCE="$(cd "$(dirname "$SOURCE")" && pwd)/$(basename "$SOURCE")"
cd "$(dirname "$0")/.."

ICONSET="AppIcon.iconset"
rm -rf "$ICONSET"
mkdir "$ICONSET"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" > /dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" > /dev/null
done

iconutil -c icns "$ICONSET" -o Assets/AppIcon.icns
rm -rf "$ICONSET"

echo "Created Assets/AppIcon.icns."
echo "Run Scripts/build-app.sh to bundle it into the app."
