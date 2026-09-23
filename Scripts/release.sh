#!/bin/bash
# Scripts/release.sh
#
# Builds MobaMac, zips it, and publishes a GitHub Release for whatever
# version is currently set in Scripts/build-app.sh -- so sharing a new
# build with someone becomes "bump the version in Scripts/build-app.sh,
# commit, run this" instead of hand-zipping and messaging a file every time.
#
# Requires the GitHub CLI (`gh`), authenticated once via `gh auth login`.
# Don't have it? This still builds and zips for you -- it just prints the
# URL to upload the zip manually instead of publishing it automatically.
#
# Usage:
#   Scripts/release.sh        (after committing whatever this release includes)
#   Scripts/release.sh notes    (only refresh the GitHub release notes for the
#                                 current version from CHANGELOG.md)
#   Scripts/release.sh appcast  (only republish docs/appcast.xml for the
#                                 current version, whose release already exists)

set -e
cd "$(dirname "$0")/.."

REPO="Crawling-Bil/mobamac"

SHORT_VERSION=$(sed -nE 's/^SHORT_VERSION="([^"]+)".*/\1/p' Scripts/build-app.sh | head -1)
if [ -z "$SHORT_VERSION" ]; then
    echo "Couldn't read SHORT_VERSION from Scripts/build-app.sh -- aborting."
    exit 1
fi
APPCAST_PATH="docs/appcast.xml"
TAG="v${SHORT_VERSION}.0"
ZIP_NAME="MobaMac-${SHORT_VERSION}.zip"

# Release notes come from this version's section of CHANGELOG.md, so the
# GitHub release says what changed instead of pointing at the commit log.
NOTES=""
if [ -f CHANGELOG.md ]; then
    NOTES=$(awk -v want="## $SHORT_VERSION" '
        $0 == want { collecting = 1; next }
        /^## / { if (collecting) exit }
        collecting { print }
    ' CHANGELOG.md)
fi
if [ -z "$(printf '%s' "$NOTES" | tr -d '[:space:]')" ]; then
    echo "No '## $SHORT_VERSION' section in CHANGELOG.md, falling back to a generic note."
    NOTES="See the commit history for what changed in this version."
fi

# `Scripts/release.sh notes` refreshes the GitHub release notes for the version
# currently in Scripts/build-app.sh and stops there. Useful when the
# build is already published and only CHANGELOG.md changed, since that
# needs no rebuild, no new tag and no new version number.
if [ "$1" = "notes" ]; then
    if ! command -v gh >/dev/null 2>&1; then
        echo "gh CLI not found. Install it with:  brew install gh"
        exit 1
    fi
    echo "== Updating release notes for $TAG =="
    gh release edit "$TAG" --repo "$REPO" --notes "$NOTES"
    echo "Done -- https://github.com/$REPO/releases/tag/$TAG"
    exit 0
fi

NOTES_FILE=$(mktemp)
printf '%s\n' "$NOTES" > "$NOTES_FILE"
trap 'rm -f "$NOTES_FILE"' EXIT

# Regenerates docs/appcast.xml, which is what installed copies poll.
#
# generate_appcast is pointed at a folder holding only this release's zip,
# never at a folder of every past release: it stamps whatever it finds with
# the --download-url-prefix of the current run, so a shared folder would
# rewrite old items to point at this tag and 404 for anyone still on an
# older version. merge-appcast.py splices the one new item into the
# published feed and leaves every older item exactly as it was.
publish_appcast() {
    local generate_appcast stage
    generate_appcast=$(find .build/artifacts -type f -name generate_appcast 2>/dev/null | head -1)
    if [ -z "$generate_appcast" ]; then
        echo "!! generate_appcast not found under .build/artifacts."
        echo "!! Run 'swift package resolve', then 'Scripts/release.sh appcast' to publish the feed."
        return 0
    fi

    echo "== Generating appcast entry for $SHORT_VERSION =="
    stage=$(mktemp -d)
    cp "$ZIP_NAME" "$stage/"
    # The EdDSA private key is read from the login keychain, where
    # generate_keys put it. It is never in this repo.
    "$generate_appcast" \
        --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
        --link "https://github.com/$REPO/releases/tag/$TAG" \
        -o "$stage/appcast.xml" \
        "$stage"

    mkdir -p "$(dirname "$APPCAST_PATH")"
    python3 Scripts/merge-appcast.py "$stage/appcast.xml" "$APPCAST_PATH" "$SHORT_VERSION" "$NOTES_FILE"
    rm -rf "$stage"

    if git diff --quiet -- "$APPCAST_PATH"; then
        echo "$APPCAST_PATH unchanged."
        return 0
    fi
    echo "== Publishing $APPCAST_PATH =="
    git add "$APPCAST_PATH"
    git commit -m "Appcast: MobaMac $SHORT_VERSION"
    git push origin main
}

# `Scripts/release.sh appcast` republishes the feed for a version whose
# GitHub release already exists -- the recovery path when the release went
# out but the appcast step didn't.
if [ "$1" = "appcast" ]; then
    ZIP_NAME_LOCAL="$ZIP_NAME"
    if [ ! -f "$ZIP_NAME_LOCAL" ]; then
        echo "== Fetching $ZIP_NAME from release $TAG =="
        gh release download "$TAG" --repo "$REPO" --pattern "$ZIP_NAME" --clobber
    fi
    publish_appcast
    exit 0
fi

echo "== Building MobaMac $SHORT_VERSION =="
Scripts/build-app.sh --no-open

echo "== Zipping /Applications/MobaMac.app -> $ZIP_NAME =="
rm -f "$ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent /Applications/MobaMac.app "$ZIP_NAME"

echo "== Pushing commits =="
git push origin main

echo "== Tagging $TAG =="
if git rev-parse "$TAG" >/dev/null 2>&1; then
    if [ "$(git rev-list -n1 "$TAG")" != "$(git rev-parse HEAD)" ]; then
        echo "Tag $TAG already exists but points at a different commit."
        echo "That would publish this build under a tag pointing at older code."
        echo "Bump CFBundleShortVersionString in Scripts/build-app.sh, commit, then run this again."
        exit 1
    fi
    echo "Tag $TAG already exists at this commit."
else
    git tag -a "$TAG" -m "$TAG"
fi
git push origin "$TAG" || echo "($TAG already on the remote -- continuing)"

if command -v gh >/dev/null 2>&1; then
    echo "== Publishing GitHub Release $TAG =="
    if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
        echo "Release $TAG already exists -- uploading $ZIP_NAME to it (replacing any existing asset)."
        gh release upload "$TAG" "$ZIP_NAME" --repo "$REPO" --clobber
        gh release edit "$TAG" --repo "$REPO" --notes "$NOTES" --latest
    else
        gh release create "$TAG" "$ZIP_NAME" \
            --repo "$REPO" \
            --title "MobaMac $SHORT_VERSION" \
            --notes "$NOTES" \
            --latest
    fi
    publish_appcast
    rm -f "$ZIP_NAME"
    echo ""
    echo "Done -- https://github.com/$REPO/releases/tag/$TAG"
    echo "The README's download link (releases/latest) now points at this build."
    echo "Installed copies see this version within a day, or right away via Check for Updates."
else
    echo ""
    echo "gh CLI not found. Install it with:  brew install gh"
    echo "Then run:  gh auth login   (once)"
    echo "...and re-run this script -- or upload $ZIP_NAME by hand at:"
    echo "https://github.com/$REPO/releases/new?tag=$TAG"
fi
