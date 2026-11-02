#!/bin/bash
# Build, sign, package and publish a release, including the Sparkle appcast.
#
# Releases ship a .dmg rather than a .zip: the image holds the app next to an
# Applications symlink, so installing is one drag instead of extract-then-drag.
# Sparkle reads the DMG directly, so the appcast points at it.
#
# The appcast is a static file served from the release itself:
#   https://github.com/xdzgithub/FocusTrafficLight/releases/latest/download/appcast.xml
# so publishing it is the last step of a release. It must be regenerated here
# rather than by hand, because generate_appcast is what writes the EdDSA
# signature — a hand-written appcast has no `sparkle:edSignature`, and every
# update built from it will be rejected by the running app.
#
# Re-running for a version that is already published replaces that release's
# assets instead of failing on the existing tag, so the artifact format can be
# changed without bumping the version.
#
# Usage:  ./scripts/release.sh 27.2.0
set -euo pipefail

VERSION="${1:?usage: release.sh <version>  e.g. release.sh 27.2.0}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="Focus TrafficLight"
BUILD_DIR="$REPO_ROOT/Build/Build/Products/Release"
STAGE="$REPO_ROOT/build/release"
ARCHIVES="$STAGE/archives"
DMG_NAME="FocusTrafficLight_v${VERSION}.dmg"

echo "==> Version in Info.plist / project.yml must already be $VERSION"
grep -q "<string>$VERSION</string>" Resources/Info.plist \
  || { echo "Resources/Info.plist does not say $VERSION"; exit 1; }
grep -q "MARKETING_VERSION: \"$VERSION\"" project.yml \
  || { echo "project.yml does not say $VERSION"; exit 1; }

echo "==> Clean build"
rm -rf "$BUILD_DIR"
xcodebuild -project FocusTrafficLight.xcodeproj -scheme FocusTrafficLight \
  -configuration Release -derivedDataPath Build clean build \
  | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"

APP="$BUILD_DIR/$APP_NAME.app"
[ -d "$APP" ] || { echo "no app at $APP"; exit 1; }

echo "==> Build the disk image"
rm -rf "$STAGE"; mkdir -p "$ARCHIVES"
DMG_SRC="$STAGE/dmg-src"
mkdir -p "$DMG_SRC"
# ditto, not cp: it preserves the bundle's extended attributes and signature.
/usr/bin/ditto "$APP" "$DMG_SRC/$APP_NAME.app"
# The symlink is what makes the image drag-to-install rather than browse-only.
ln -s /Applications "$DMG_SRC/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_SRC" -ov -quiet \
  -format UDZO "$ARCHIVES/$DMG_NAME"
rm -rf "$DMG_SRC"

echo "==> Generate appcast (writes the EdDSA signature)"
SPARKLE_TOOLS="$REPO_ROOT/Build/SourcePackages/artifacts/sparkle/Sparkle/bin"
"$SPARKLE_TOOLS/generate_appcast" \
  --download-url-prefix "https://github.com/xdzgithub/FocusTrafficLight/releases/download/v${VERSION}/" \
  -o "$STAGE/appcast.xml" \
  "$ARCHIVES"

grep -q "sparkle:edSignature=" "$STAGE/appcast.xml" \
  || { echo "appcast has no signature — updates would be rejected"; exit 1; }
grep -q "$DMG_NAME" "$STAGE/appcast.xml" \
  || { echo "appcast does not point at $DMG_NAME"; exit 1; }
echo "    version in appcast:"
grep -E "shortVersionString|sparkle:version>|enclosure url" "$STAGE/appcast.xml" | sed 's/^/      /'

echo "==> Verify the image installs a signed app"
MOUNT_POINT=$(hdiutil attach -nobrowse -readonly -plist "$ARCHIVES/$DMG_NAME" \
  | plutil -extract system-entities xml1 -o - - \
  | python3 -c 'import sys, plistlib; d=plistlib.loads(sys.stdin.buffer.read()); print(next(e["mount-point"] for e in d if "mount-point" in e))')
codesign --verify --deep --strict "$MOUNT_POINT/$APP_NAME.app" \
  || { hdiutil detach "$MOUNT_POINT" -quiet; echo "signature broken inside the image"; exit 1; }
[ -L "$MOUNT_POINT/Applications" ] \
  || { hdiutil detach "$MOUNT_POINT" -quiet; echo "image has no Applications symlink"; exit 1; }
hdiutil detach "$MOUNT_POINT" -quiet
echo "    signature ok, Applications symlink present"

echo "==> Publish"
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
  echo "    v$VERSION is already tagged — replacing its assets"
  # The appcast names the image, so any older format in the release would be a
  # dead download. Drop every archive asset, then re-upload what this run built.
  gh release view "v$VERSION" --json assets --jq '.assets[].name' \
    | grep -E '\.(zip|dmg)$' | while read -r stale; do
        echo "    removing $stale"
        gh release delete-asset "v$VERSION" "$stale" --yes
      done
  # Image first: a feed that points at a missing asset is worse than no feed.
  gh release upload "v$VERSION" "$ARCHIVES/$DMG_NAME" --clobber
  gh release upload "v$VERSION" "$STAGE/appcast.xml" --clobber
else
  git tag -a "v$VERSION" -m "v$VERSION"
  git push origin "v$VERSION"
  gh release create "v$VERSION" \
    "$ARCHIVES/$DMG_NAME" \
    "$STAGE/appcast.xml" \
    --title "v$VERSION" \
    --notes-file "${NOTES_FILE:-/dev/stdin}"
fi

echo "==> Done: v$VERSION"
echo "    Feed: https://github.com/xdzgithub/FocusTrafficLight/releases/latest/download/appcast.xml"
