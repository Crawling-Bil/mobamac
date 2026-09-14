#!/bin/bash
# make-icon.sh
#
# Converts a single square PNG (1024x1024 recommended) into AppIcon.icns,
# using only tools already built into macOS (sips + iconutil) — no extra
# installs needed.
#
# Usage:
#   chmod +x make-icon.sh   (once)
#   ./make-icon.sh path/to/your-logo.png

set -e

SOURCE="$1"
if [ -z "$SOURCE" ]; then
    echo "Usage: ./make-icon.sh path/to/your-logo.png"
    exit 1
fi
if [ ! -f "$SOURCE" ]; then
    echo "File not found: $SOURCE"
    exit 1
fi

ICONSET="AppIcon.iconset"
rm -rf "$ICONSET"
mkdir "$ICONSET"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" > /dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" > /dev/null
done

iconutil -c icns "$ICONSET" -o AppIcon.icns
rm -rf "$ICONSET"

echo "Created AppIcon.icns in the current folder."
echo "Now run ./package-mobamac-app.sh again to bundle it into the app."
