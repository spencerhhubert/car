#!/bin/bash
# Build, sign and install owl. Two copies, side by side:
#
#   ./build.sh            the development copy: /Applications/owl-dev.app and
#                         the owl-dev command, with its own sessions, settings,
#                         log and permissions (Application Support/owl-dev).
#                         Its gesture is off until turned on from its menu.
#                         Only owl-dev is ever stopped or replaced.
#   ./build.sh release    the owl in use: /Applications/owl.app and the owl
#                         command. Refuses while it is recording or
#                         transcribing; otherwise quits it (a quit closes a
#                         session properly) and swaps in the new build.
#
# Each copy is installed at a fixed path and signed with a stable identity on
# purpose: macOS keys the Accessibility, Microphone, Screen Recording and
# Automation grants to bundle id + signing identity + path, and a path that
# changes every build loses them. The two copies have separate grants.
#
# Signing: the first "Apple Development" identity in the keychain, with the
# team read off its certificate, so nothing about an account is written here.
# With no such identity the build signs ad hoc, which works for a local run
# but re-prompts for every grant after each rebuild.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export PATH="/opt/homebrew/bin:$PATH"

case "${1:-dev}" in
    dev) NAME=owl-dev; BUNDLE_ID=com.owl.mac.dev ;;
    release) NAME=owl; BUNDLE_ID=com.owl.mac ;;
    *) echo "usage: ./build.sh [release]" >&2; exit 2 ;;
esac
APP="/Applications/$NAME.app"
DERIVED="$HERE/.build/$NAME"

IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2; exit}' || true)"
TEAM=""
if [ -n "$IDENTITY" ]; then
    TEAM="$(security find-certificate -c "Apple Development" -p \
        | openssl x509 -noout -subject | sed -E 's/.*OU ?= ?([A-Z0-9]+).*/\1/')"
fi

cd "$HERE"
[ -d owl/Assets.xcassets ] || swift tools/make-icon.swift
xcodegen >/dev/null

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
codesign --force --deep --options runtime --entitlements "$HERE/owl/owl.entitlements" --sign "$SIGN" "$APP"
codesign --verify --strict "$APP"

mkdir -p "$HOME/.local/bin"
ln -sf "$APP/Contents/MacOS/$NAME" "$HOME/.local/bin/$NAME"
echo "==> installed $APP; the command is $HOME/.local/bin/$NAME"
open "$APP"
