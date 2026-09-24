#!/bin/bash
# Build, sign and install the development copy of owl: /Applications/owl-dev.app
# and the owl-dev command, with its own catalog, sessions, settings, log and
# permissions (Application Support/owl-dev). Its keys are off until turned on
# from its menu. Only owl-dev is ever stopped or replaced; the owl in use
# comes from a release (tools/release.sh) and updates itself.
#
#   ./build.sh
#
# The copy is installed at a fixed path and signed with a stable identity on
# purpose: macOS keys the Accessibility, Microphone, Screen Recording and
# Automation grants to bundle id + signing identity + path, and a path that
# changes every build loses them.
#
# Signing: the first "Apple Development" identity in the keychain, with the
# team read off its certificate, so nothing about an account is written here.
# With no such identity the build signs ad hoc, which works for a local run
# but re-prompts for every grant after each rebuild.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export PATH="/opt/homebrew/bin:$PATH"
[ $# -eq 0 ] || { echo "usage: ./build.sh (the dev copy; releases are tools/release.sh)" >&2; exit 2; }
NAME=owl-dev
BUNDLE_ID=com.owl.mac.dev
APP="/Applications/$NAME.app"
DERIVED="$HERE/.build/$NAME"

IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2; exit}' || true)"
TEAM=""
if [ -n "$IDENTITY" ]; then
    TEAM="$(security find-certificate -c "Apple Development" -p \
        | openssl x509 -noout -subject | sed -E 's/.*OU ?= ?([A-Z0-9]+).*/\1/')"
fi

cd "$HERE"
[ -d App/Assets.xcassets ] || swift tools/make-icon.swift
xcodegen >/dev/null

echo "==> testing OwlKit"
swift test --package-path OwlKit -q 2>&1 | tail -5 || { echo "tests failed; nothing installed" >&2; exit 1; }

echo "==> building $NAME"
if [ -n "$IDENTITY" ]; then
    SIGNING=(CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="$TEAM")
else
    SIGNING=(CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="")
fi
LOG="$DERIVED/build.log"
mkdir -p "$DERIVED"
if ! xcodebuild -project owl.xcodeproj -scheme owl -configuration Release -derivedDataPath "$DERIVED" \
        PRODUCT_NAME="$NAME" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" CODE_SIGN_STYLE=Manual \
        MARKETING_VERSION="dev-$(git rev-parse --short HEAD)" \
        "${SIGNING[@]}" build >"$LOG" 2>&1; then
    grep -E 'error:' "$LOG" | sort -u | head -30
    echo "build failed; the whole log is $LOG" >&2
    exit 1
fi
grep -E 'warning:' "$LOG" | grep -v 'appintentsmetadataprocessor' | sort -u | head -20 || true
BUILT="$DERIVED/Build/Products/Release/$NAME.app"
[ -d "$BUILT" ] || { echo "build produced no app" >&2; exit 1; }

# The new build's own command reads the same folder as the installed copy, so
# it can say whether that copy is in the middle of a session.
if ! "$BUILT/Contents/MacOS/$NAME" status >/dev/null; then
    echo "$NAME is busy; not replacing it now:" >&2
    "$BUILT/Contents/MacOS/$NAME" status >&2 || true
    exit 1
fi

# Quit the running copy, found by bundle id so an `owl session` someone is
# waiting on is never touched. SIGTERM is a quit: owl closes a session that
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

rm -rf "$APP"
cp -R "$BUILT" "$APP"
SIGN="${IDENTITY:--}"
echo "==> signing $APP"
codesign --force --deep --options runtime --entitlements "$HERE/App/owl.entitlements" --sign "$SIGN" "$APP"
codesign --verify --strict "$APP"

echo "==> installed $APP; it links $HOME/.local/bin/$NAME when it starts"
open "$APP"
