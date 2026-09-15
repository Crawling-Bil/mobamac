#!/bin/bash
# release.sh
#
# Builds MobaMac, zips it, and publishes a GitHub Release for whatever
# version is currently set in package-mobamac-app.sh -- so sharing a new
# build with someone becomes "bump the version in package-mobamac-app.sh,
# commit, run this" instead of hand-zipping and messaging a file every time.
#
# Requires the GitHub CLI (`gh`), authenticated once via `gh auth login`.
# Don't have it? This still builds and zips for you -- it just prints the
# URL to upload the zip manually instead of publishing it automatically.
#
# Usage:
#   chmod +x release.sh   (once)
#   ./release.sh          (run from inside the MobaMac project folder,
#                           after committing whatever this release includes)

set -e

REPO="Crawling-Bil/mobamac"

SHORT_VERSION=$(grep -A1 "CFBundleShortVersionString" package-mobamac-app.sh | tail -1 | sed -E 's/.*<string>(.*)<\/string>.*/\1/')
if [ -z "$SHORT_VERSION" ]; then
    echo "Couldn't read CFBundleShortVersionString from package-mobamac-app.sh -- aborting."
    exit 1
fi
TAG="v${SHORT_VERSION}.0"
ZIP_NAME="MobaMac-${SHORT_VERSION}.zip"

echo "== Building MobaMac $SHORT_VERSION =="
./package-mobamac-app.sh

echo "== Zipping /Applications/MobaMac.app -> $ZIP_NAME =="
rm -f "$ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent /Applications/MobaMac.app "$ZIP_NAME"

echo "== Pushing commits =="
git push origin main

echo "== Tagging $TAG =="
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "Tag $TAG already exists locally."
else
    git tag -a "$TAG" -m "$TAG"
fi
git push origin "$TAG" || echo "($TAG already on the remote -- continuing)"

if command -v gh >/dev/null 2>&1; then
    echo "== Publishing GitHub Release $TAG =="
    if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
        echo "Release $TAG already exists -- uploading $ZIP_NAME to it (replacing any existing asset)."
        gh release upload "$TAG" "$ZIP_NAME" --repo "$REPO" --clobber
        gh release edit "$TAG" --repo "$REPO" --latest
    else
        gh release create "$TAG" "$ZIP_NAME" \
            --repo "$REPO" \
            --title "MobaMac $SHORT_VERSION" \
            --notes "See the commit history for what changed in this version." \
            --latest
    fi
    rm -f "$ZIP_NAME"
    echo ""
    echo "Done -- https://github.com/$REPO/releases/tag/$TAG"
    echo "The README's download link (releases/latest) now points at this build."
else
    echo ""
    echo "gh CLI not found. Install it with:  brew install gh"
    echo "Then run:  gh auth login   (once)"
    echo "...and re-run this script -- or upload $ZIP_NAME by hand at:"
    echo "https://github.com/$REPO/releases/new?tag=$TAG"
fi
