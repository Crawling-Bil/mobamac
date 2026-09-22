#!/bin/bash
# Scripts/build-app.sh
#
# Builds MobaMac with `swift build` (no Xcode GUI needed), wraps the binary
# in a real MobaMac.app bundle, and installs it to /Applications.
#
# The app's version lives in the Info.plist below
# (CFBundleShortVersionString / CFBundleVersion); release.sh reads it from
# here.
#
# Usage (from anywhere):
#   Scripts/build-app.sh

set -e
cd "$(dirname "$0")/.."

APP_NAME="MobaMac"
BUNDLE_ID="com.aldi.mobamac"
DEST="/Applications/$APP_NAME.app"

echo "Building release configuration..."
swift build -c release

BINARY=$(find .build -type f -name "$APP_NAME" -path "*release*" ! -path "*.dSYM*" | head -1)

if [ -z "$BINARY" ]; then
    echo "Couldn't find the built binary under .build/ — check the build succeeded above."
    exit 1
fi

echo "Found binary: $BINARY"

WORKDIR=$(mktemp -d)
BUNDLE_DIR="$WORKDIR/$APP_NAME.app"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

cp "$BINARY" "$BUNDLE_DIR/Contents/MacOS/$APP_NAME"

ICON_KEY=""
if [ -f "Assets/AppIcon.icns" ]; then
    cp "Assets/AppIcon.icns" "$BUNDLE_DIR/Contents/Resources/AppIcon.icns"
    ICON_KEY="    <key>CFBundleIconFile</key>
    <string>AppIcon</string>"
    echo "Bundling AppIcon.icns"
else
    echo "No Assets/AppIcon.icns found, so the app will use the default icon. Run Scripts/make-icon.sh first for a custom one."
fi

cat > "$BUNDLE_DIR/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.13</string>
    <key>CFBundleVersion</key>
    <string>14</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
$ICON_KEY
</dict>
</plist>
EOF

echo "Signing (ad-hoc, local use only)..."
codesign --force --deep --sign - "$BUNDLE_DIR"

echo "Quitting any running instance..."
osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true

echo "Installing to $DEST..."
rm -rf "$DEST"
cp -R "$BUNDLE_DIR" "$DEST"
rm -rf "$WORKDIR"

echo "Done. Opening..."
open "$DEST"
