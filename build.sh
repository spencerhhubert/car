#!/bin/bash
# Build, sign and install car on this Mac. Two copies, side by side:
#
#   ./build.sh            the development copy: /Applications/car-dev.app and
#                         the car-dev command, with its own catalog, sessions,
#                         settings, log and permissions (Application
#                         Support/car-dev). Its keys are off until turned on
#                         from its menu. Only car-dev is stopped or replaced.
#   ./build.sh release    the car in use: /Applications/car.app and the car
#                         command. Refuses while it is recording or
#                         transcribing; otherwise quits it (a quit closes a
#                         session properly) and swaps in the new build.
#
# car is not distributed as a download: whoever wants it builds it with this.
# Each copy is installed at a fixed path and signed with a stable identity on
# purpose: macOS keys the Accessibility, Microphone, Screen Recording and
# Automation grants to the bundle id and the certificate the app is signed
# with. A rebuild signed the same way keeps them; a new bundle id or a new
# certificate starts over, and every grant is asked for again. The two copies
# have separate grants.
#
# Signing: the certificate the installed copy is already signed with, while
# it is valid, so a new certificate in the keychain never changes it; else
# the first valid "Apple Development" identity. The team is read off that
# certificate, so nothing about an account is written here. A build that
# would be signed differently from the installed copy says so, and for the
# real car stops unless NEW_SIGNATURE=1. With no identity at all the build
# signs ad hoc, which works for a local run but asks for every grant after
# each rebuild.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export PATH="/opt/homebrew/bin:$PATH"

case "${1:-dev}" in
    dev) NAME=car-dev; BUNDLE_ID=com.car.mac.dev ;;
    release) NAME=car; BUNDLE_ID=com.car.mac ;;
    *) echo "usage: ./build.sh [release]" >&2; exit 2 ;;
esac
APP="/Applications/$NAME.app"
DERIVED="$HERE/.build/$NAME"

VALID="$(security find-identity -v -p codesigning | grep 'Apple Development' || true)"
SIGNER="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Apple Development: .*\)$/\1/p' | head -1 || true)"
IDENTITY=""
[ -n "$SIGNER" ] && IDENTITY="$(echo "$VALID" | grep -F "\"$SIGNER\"" | awk '{print $2; exit}' || true)"
[ -n "$IDENTITY" ] || IDENTITY="$(echo "$VALID" | awk '{print $2; exit}' || true)"
TEAM=""
if [ -n "$IDENTITY" ]; then
    TEAM="$(security find-certificate -a -Z -p | awk -v h="$IDENTITY" '/^SHA-1 hash:/{keep=($3==h); next} /^SHA-256 hash:/{next} keep' \
        | openssl x509 -noout -subject | sed -E 's/.*OU ?= ?([A-Z0-9]+).*/\1/')"
fi

cd "$HERE"
[ -d App/Assets.xcassets ] || swift tools/make-icon.swift
xcodegen >/dev/null

echo "==> testing CarKit"
swift test --package-path CarKit -q 2>&1 | tail -5 || { echo "tests failed; nothing installed" >&2; exit 1; }

echo "==> building $NAME"
if [ -n "$IDENTITY" ]; then
    SIGNING=(CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="$TEAM")
else
    SIGNING=(CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="")
fi
LOG="$DERIVED/build.log"
mkdir -p "$DERIVED"
if ! xcodebuild -project car.xcodeproj -scheme car -configuration Release -derivedDataPath "$DERIVED" \
        PRODUCT_NAME="$NAME" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" CODE_SIGN_STYLE=Manual \
        MARKETING_VERSION="$(git -C "$HERE" describe --always --dirty)" \
        "${SIGNING[@]}" build >"$LOG" 2>&1; then
    grep -E 'error:' "$LOG" | sort -u | head -30
    echo "build failed; the whole log is $LOG" >&2
    exit 1
fi
grep -E 'warning:' "$LOG" | grep -v 'appintentsmetadataprocessor' | sort -u | head -20 || true
BUILT="$DERIVED/Build/Products/Release/$NAME.app"
[ -d "$BUILT" ] || { echo "build produced no app" >&2; exit 1; }

SIGN="${IDENTITY:--}"
echo "==> signing $NAME"
codesign --force --deep --options runtime --entitlements "$HERE/App/car.entitlements" --sign "$SIGN" "$BUILT"
codesign --verify --strict "$BUILT"

# The grants belong to how the installed copy is signed. A build signed any
# other way would lose them all.
if [ -d "$APP" ]; then
    OLD="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
    NEW="$(codesign -d -r- "$BUILT" 2>&1 | sed -n 's/^designated => //p')"
    if [ "$OLD" != "$NEW" ]; then
        echo "this build is signed differently from the installed $NAME, so macOS would ask for every permission again:" >&2
        echo "  installed:  $OLD" >&2
        echo "  this build: $NEW" >&2
        if [ "$NAME" = car ] && [ "${NEW_SIGNATURE:-0}" != 1 ]; then
            echo "not installing; NEW_SIGNATURE=1 ./build.sh release installs it anyway" >&2
            exit 1
        fi
    fi
fi

# The new build's own command reads the same folder as the installed copy, so
# it can say whether that copy is in the middle of a session.
if ! "$BUILT/Contents/MacOS/$NAME" status >/dev/null; then
    echo "$NAME is busy; not replacing it now:" >&2
    "$BUILT/Contents/MacOS/$NAME" status >&2 || true
    exit 1
fi

# Quit the running copy, found by bundle id so a `car session` someone is
# waiting on is never touched. SIGTERM is a quit: car closes a session that
# started in the last moment rather than cutting it off.
PID="$(lsappinfo info -only pid -app "$BUNDLE_ID" | sed -nE 's/.*"pid"=([0-9]+).*/\1/p')"
if [ -n "$PID" ]; then
    echo "==> quitting the running $NAME ($PID)"
    kill -TERM "$PID"
    for _ in $(seq 1 50); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$PID" 2>/dev/null; then
        echo "$NAME ($PID) did not quit within 5 s; leaving it running and not installing" >&2
        exit 1
    fi
fi

# Copied with its signature, which ditto keeps intact.
rm -rf "$APP"
ditto "$BUILT" "$APP"
codesign --verify --strict "$APP"

echo "==> installed $APP; it links $HOME/.local/bin/$NAME when it starts"
# Started hidden and in the background: a build never puts a window in front
# of the person. The Dock icon shows it.
open -g -j "$APP"
