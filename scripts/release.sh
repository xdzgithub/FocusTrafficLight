#!/bin/bash
# Build, sign, package and publish a release, including the Sparkle appcast.
#
# The appcast is a static file served from the release itself:
#   https://github.com/xdzgithub/FocusTrafficLight/releases/latest/download/appcast.xml
# so publishing it is the last step of a release. It must be regenerated here
# rather than by hand, because generate_appcast is what writes the EdDSA
# signature — a hand-written appcast has no `sparkle:edSignature`, and every
# update built from it will be rejected by the running app.
#
# Usage:  ./scripts/release.sh 5.0.5
set -euo pipefail

VERSION="${1:?usage: release.sh <version>  e.g. release.sh 5.0.5}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="Focus Traffic Light"
BUILD_DIR="$REPO_ROOT/Build/Build/Products/Release"
STAGE="$REPO_ROOT/build/release"
ZIP_NAME="FocusTrafficLight_v${VERSION}.zip"

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

echo "==> Stage the archive"
rm -rf "$STAGE"; mkdir -p "$STAGE"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGE/$ZIP_NAME"

echo "==> Generate appcast (writes the EdDSA signature)"
SPARKLE_TOOLS="$REPO_ROOT/Build/SourcePackages/artifacts/sparkle/Sparkle/bin"
"$SPARKLE_TOOLS/generate_appcast" \
  --download-url-prefix "https://github.com/xdzgithub/FocusTrafficLight/releases/download/v${VERSION}/" \
  -o "$STAGE/appcast.xml" \
  "$STAGE"

grep -q "sparkle:edSignature=" "$STAGE/appcast.xml" \
  || { echo "appcast has no signature — updates would be rejected"; exit 1; }
echo "    version in appcast:"
grep -E "shortVersionString|sparkle:version>" "$STAGE/appcast.xml" | sed 's/^/      /'

echo "==> Verify the archive keeps its signature after extraction"
VERIFY="$STAGE/verify"; mkdir -p "$VERIFY"
/usr/bin/ditto -x -k "$STAGE/$ZIP_NAME" "$VERIFY"
codesign --verify --deep --strict "$VERIFY/$APP_NAME.app" \
  || { echo "signature broken in the archive"; exit 1; }
rm -rf "$VERIFY"

echo "==> Publish"
git tag -a "v$VERSION" -m "v$VERSION"
git push origin "v$VERSION"
gh release create "v$VERSION" \
  "$STAGE/$ZIP_NAME" \
  "$STAGE/appcast.xml" \
  --title "v$VERSION" \
  --notes-file "${NOTES_FILE:-/dev/stdin}"

echo "==> Done: v$VERSION"
echo "    Feed: https://github.com/xdzgithub/FocusTrafficLight/releases/latest/download/appcast.xml"
