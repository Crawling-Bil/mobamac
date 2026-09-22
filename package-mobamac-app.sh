#!/bin/bash
# package-mobamac-app.sh
#
# Builds MobaMac via `swift build` (no Xcode GUI needed) and wraps the raw
# binary into a real MobaMac.app bundle, then installs it to /Applications.
#
# Use this instead of update-mobamac.sh if the project is being built via
# `swift build`/`swift run` from the terminal rather than Xcode's Run
# button — that path never produces a real .app, just a bare executable
# under .build/, which is why update-mobamac.sh couldn't find anything.
#
# Usage:
#   chmod +x package-mobamac-app.sh   (once)
#   ./package-mobamac-app.sh          (run from inside the MobaMac project folder)

set -e

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
if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "$BUNDLE_DIR/Contents/Resources/AppIcon.icns"
    ICON_KEY="    <key>CFBundleIconFile</key>
    <string>AppIcon</string>"
    echo "Bundling AppIcon.icns"
else
    echo "No AppIcon.icns found in this folder — app will use the default icon. Run make-icon.sh first if you want a custom one."
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
    <string>1.10</string>
    <key>CFBundleVersion</key>
    <string>11</string>
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
