#!/bin/bash
# Scripts/build-app.sh
#
# Builds MobaMac with `swift build` (no Xcode GUI needed), wraps the binary
# in a real MobaMac.app bundle, and installs it to /Applications.
#
# The app's version lives in SHORT_VERSION / BUNDLE_VERSION below;
# release.sh reads SHORT_VERSION from here.
#
# Usage (from anywhere):
#   Scripts/build-app.sh             build, install, and launch
#   Scripts/build-app.sh --no-open   build and install only (release.sh uses this)
#
# Environment:
#   MOBAMAC_SIGN_IDENTITY   code signing identity to use. Defaults to the
#                           self-signed certificate named below. Set it to
#                           "-" to go back to ad-hoc signing, but read the
#                           note on SIGN_IDENTITY first.

set -e
cd "$(dirname "$0")/.."

OPEN_AFTER_INSTALL=1
if [ "$1" = "--no-open" ]; then
    OPEN_AFTER_INSTALL=0
fi

APP_NAME="MobaMac"
BUNDLE_ID="com.aldi.mobamac"
DEST="/Applications/$APP_NAME.app"

SHORT_VERSION="1.16"
BUNDLE_VERSION="20"

# Where Sparkle looks for the list of available versions. Served by GitHub
# Pages from the docs/ folder on main, which release.sh updates. Must be
# https, and deliberately not raw.githubusercontent.com: that is cached hard
# enough that a new release can stay invisible for hours.
APPCAST_URL="https://crawling-bil.github.io/mobamac/appcast.xml"
PUBKEY_FILE="Scripts/sparkle-public-key.txt"

# Ad-hoc signing ("-") mints a brand-new identity on every build, and macOS
# treats a differently-signed binary as a different application. Every saved
# SSH password would then prompt for Keychain access again after each
# update, which for this app means a prompt per session. A self-signed
# certificate keeps one stable identity across builds instead.
# README "Code signing certificate" has the four steps to create one.
SIGN_IDENTITY="${MOBAMAC_SIGN_IDENTITY:-MobaMac Self-Signed}"

if [ "$SIGN_IDENTITY" != "-" ] && ! security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY"; then
    cat >&2 <<MSG
Code signing certificate "$SIGN_IDENTITY" was not found in your keychain.

Create it once (Keychain Access > Certificate Assistant > Create a
Certificate): name it "$SIGN_IDENTITY", Identity Type "Self Signed Root",
Certificate Type "Code Signing". README "Code signing certificate" has the
full walkthrough.

To build without it anyway:  MOBAMAC_SIGN_IDENTITY=- Scripts/build-app.sh
That is ad-hoc signing, and macOS will re-ask for Keychain access to every
saved SSH password after each build.
MSG
    exit 1
fi

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
mkdir -p "$BUNDLE_DIR/Contents/Frameworks"

cp "$BINARY" "$BUNDLE_DIR/Contents/MacOS/$APP_NAME"

# Sparkle ships as an XCFramework through SwiftPM. `swift build` links
# against it but has no concept of an app bundle, so the framework has to be
# copied in and the binary taught where to look for it at runtime.
# -type d skips the compatibility symlinks at the framework root, and
# /extract/ is SwiftPM's temporary unzip staging, which it empties again.
SPARKLE_FRAMEWORK=$(find .build/artifacts -type d -name "Sparkle.framework" -path "*macos*" ! -path "*/extract/*" 2>/dev/null | head -1)
if [ -z "$SPARKLE_FRAMEWORK" ]; then
    echo "Couldn't find Sparkle.framework under .build/artifacts — run 'swift package resolve' and try again."
    exit 1
fi
echo "Bundling $(basename "$(dirname "$SPARKLE_FRAMEWORK")")/Sparkle.framework"
# ditto, not cp: the framework is a versioned bundle held together by
# symlinks that cp -R does not reproduce faithfully enough for codesign.
ditto "$SPARKLE_FRAMEWORK" "$BUNDLE_DIR/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BUNDLE_DIR/Contents/MacOS/$APP_NAME" 2>/dev/null || true

ICON_KEY=""
if [ -f "Assets/AppIcon.icns" ]; then
    cp "Assets/AppIcon.icns" "$BUNDLE_DIR/Contents/Resources/AppIcon.icns"
    ICON_KEY="    <key>CFBundleIconFile</key>
    <string>AppIcon</string>"
    echo "Bundling AppIcon.icns"
else
    echo "No Assets/AppIcon.icns found, so the app will use the default icon. Run Scripts/make-icon.sh first for a custom one."
fi

# The EdDSA public key is what the app checks every downloaded update
# against. Without it there is nothing to verify signatures with, so the
# Sparkle keys are left out entirely rather than half-configured: the app
# still builds and runs, it just won't offer updates.
SPARKLE_KEYS=""
PUBKEY=""
if [ -f "$PUBKEY_FILE" ]; then
    PUBKEY=$(tr -d '[:space:]' < "$PUBKEY_FILE")
fi
if [ -n "$PUBKEY" ]; then
    SPARKLE_KEYS="    <key>SUFeedURL</key>
    <string>$APPCAST_URL</string>
    <key>SUPublicEDKey</key>
    <string>$PUBKEY</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>"
    echo "Auto-update enabled, feed: $APPCAST_URL"
else
    echo "No $PUBKEY_FILE — building without auto-update. See README \"Auto-update\" to generate a key pair."
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
    <string>$SHORT_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUNDLE_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
$SPARKLE_KEYS
$ICON_KEY
</dict>
</plist>
EOF

# Signing is inside-out on purpose. codesign seals whatever a bundle
# contains, so signing the framework first and the app afterwards is the
# only order where nothing invalidates a seal made earlier. This is also
# why there is no --deep here: --deep re-signs nested bundles that were
# already signed correctly, which is what breaks
# `codesign --verify --deep --strict` and makes generate_appcast reject the
# archive.
#
# No --options runtime either. Hardened Runtime brings library validation,
# which refuses to load a framework signed by anything other than the same
# Team ID — and a self-signed certificate has no Team ID.
SPARKLE_DEST="$BUNDLE_DIR/Contents/Frameworks/Sparkle.framework"

echo "Signing Sparkle.framework as \"$SIGN_IDENTITY\"..."
# The order and the flags here are Sparkle's own documented recipe.
#
# --preserve-metadata=entitlements on the XPC services: Installer.xpc and
# Downloader.xpc ship with entitlements, and re-signing without that flag
# drops them, which breaks the install step at the worst possible moment —
# after the update has already downloaded.
#
# The version directory is what gets signed, not the framework root: a
# versioned bundle seals per version, and Sparkle.framework's top level is
# nothing but symlinks into it.
for versiondir in "$SPARKLE_DEST"/Versions/*; do
    # Versions/Current is a symlink to the real one. Signing through it
    # would sign everything a second time and invalidate the seal just made.
    if [ -L "$versiondir" ] || [ ! -d "$versiondir" ]; then
        continue
    fi
    for xpc in "$versiondir"/XPCServices/*.xpc; do
        if [ -d "$xpc" ]; then
            codesign --force --sign "$SIGN_IDENTITY" --preserve-metadata=entitlements "$xpc"
        fi
    done
    if [ -f "$versiondir/Autoupdate" ]; then
        codesign --force --sign "$SIGN_IDENTITY" "$versiondir/Autoupdate"
    fi
    if [ -d "$versiondir/Updater.app" ]; then
        codesign --force --sign "$SIGN_IDENTITY" "$versiondir/Updater.app"
    fi
    codesign --force --sign "$SIGN_IDENTITY" "$versiondir"
done

echo "Signing $APP_NAME.app as \"$SIGN_IDENTITY\"..."
codesign --force --sign "$SIGN_IDENTITY" "$BUNDLE_DIR"

echo "Verifying signature..."
codesign --verify --deep --strict "$BUNDLE_DIR"

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
# ditto again rather than cp -R, for the framework symlinks inside.
ditto "$BUNDLE_DIR" "$DEST"
rm -rf "$WORKDIR"

if [ "$OPEN_AFTER_INSTALL" = "1" ]; then
    echo "Done. Opening..."
    # Launching is a convenience, not part of the build: if LaunchServices
    # refuses, the app is still installed and fine.
    open "$DEST" || echo "Installed to $DEST, but it couldn't be launched automatically. Open it from Applications."
else
    echo "Done. Installed to $DEST."
fi
