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
#   Scripts/build-app.sh             build, install, and launch
#   Scripts/build-app.sh --no-open   build and install only (release.sh uses this)

set -e
cd "$(dirname "$0")/.."

OPEN_AFTER_INSTALL=1
if [ "$1" = "--no-open" ]; then
    OPEN_AFTER_INSTALL=0
fi

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
    <string>1.15</string>
    <key>CFBundleVersion</key>
    <string>16</string>
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
# "quit" only asks. Wait for the process to actually be gone before
# replacing the bundle and launching it again: launching while the old
# instance is still shutting down is what makes `open` fail with
# LaunchServices error -609.
for _ in $(seq 1 20); do
    pgrep -x "$APP_NAME" >/dev/null || break
    sleep 0.25
done
if pgrep -x "$APP_NAME" >/dev/null; then
    echo "$APP_NAME is still running (a copy started from Terminal doesn't always obey quit). Close it, then run this again."
    exit 1
fi

echo "Installing to $DEST..."
rm -rf "$DEST"
cp -R "$BUNDLE_DIR" "$DEST"
rm -rf "$WORKDIR"

if [ "$OPEN_AFTER_INSTALL" = "1" ]; then
    echo "Done. Opening..."
    # Launching is a convenience, not part of the build: if LaunchServices
    # refuses, the app is still installed and fine.
    open "$DEST" || echo "Installed to $DEST, but it couldn't be launched automatically. Open it from Applications."
else
    echo "Done. Installed to $DEST."
fi
