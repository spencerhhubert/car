#!/bin/bash
# Cut a release of owl: test, build, sign with Developer ID, notarize, zip,
# tag, and publish it on the repository's GitHub releases. Every installed owl
# finds it there and offers it (App/Update/Updater.swift); a new install is
# the zip, unzipped into Applications.
#
#   tools/release.sh 0.2.0
#
# Needs: main, clean and pushed; a "Developer ID Application" identity in the
# keychain; notarization credentials stored once as the keychain profile
# "owl-notary" (`xcrun notarytool store-credentials owl-notary --key <p8>
# --key-id <id> --issuer <issuer>`); `gh` signed in. Pick the Developer ID
# identity once and keep it: macOS keys owl's permissions to it, and a new one
# means granting all four again on every Mac.
set -euo pipefail
VERSION="${1:?usage: tools/release.sh X.Y.Z}"
fail() { echo "release: $*" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "the version is X.Y.Z"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"
export PATH="/opt/homebrew/bin:$PATH"

[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || fail "release from main"
git diff --quiet && git diff --cached --quiet || fail "the tree has changes"
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main is not what origin has"
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && fail "v$VERSION exists"
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')"
[ -n "$IDENTITY" ] || fail "no Developer ID Application identity in the keychain"
TEAM="$(sed -E 's/.*\(([A-Z0-9]+)\)$/\1/' <<<"$IDENTITY")"
xcrun notarytool history --keychain-profile owl-notary >/dev/null 2>&1 || fail "no notarization profile owl-notary"
gh auth status >/dev/null 2>&1 || fail "gh is not signed in"

echo "==> testing OwlKit"
swift test --package-path OwlKit -q >/dev/null 2>&1 || fail "OwlKit's tests fail"

echo "==> building owl $VERSION"
OUT="$HERE/.build/release/$VERSION"
rm -rf "$OUT"
mkdir -p "$OUT"
xcodegen >/dev/null
xcodebuild -project owl.xcodeproj -scheme owl -configuration Release -derivedDataPath "$OUT/derived" \
    PRODUCT_NAME=owl PRODUCT_BUNDLE_IDENTIFIER=com.owl.mac MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" build >"$OUT/build.log" 2>&1 \
    || { grep -E 'error:' "$OUT/build.log" | sort -u | head -20; fail "the build failed; $OUT/build.log"; }
APP="$OUT/owl.app"
cp -R "$OUT/derived/Build/Products/Release/owl.app" "$APP"
codesign --force --deep --options runtime --timestamp --entitlements App/owl.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> notarizing"
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile owl-notary --wait
xcrun stapler staple "$APP"
spctl --assess --type execute "$APP" || fail "Gatekeeper refuses the notarized app"

ZIP="owl-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$OUT/$ZIP"
( cd "$OUT" && shasum -a 256 "$ZIP" >"$ZIP.sha256" )

LAST="$(git describe --tags --abbrev=0 2>/dev/null || true)"
{
    echo "owl $VERSION. Unzip and move owl.app to Applications; an installed owl offers the update from its menu."
    echo
    git log --format='- %s' ${LAST:+"$LAST"..HEAD}
} >"$OUT/notes.md"

echo "==> publishing v$VERSION"
git tag -a "v$VERSION" -m "owl $VERSION"
git push -q origin "v$VERSION"
gh release create "v$VERSION" "$OUT/$ZIP" "$OUT/$ZIP.sha256" --title "owl $VERSION" --notes-file "$OUT/notes.md"
echo "==> released: $(gh release view "v$VERSION" --json url --jq .url)"
