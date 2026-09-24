#!/bin/bash
# Build OwlDrive (tools/drive.swift), the live-test driver, and with a host,
# put it and the dev copy of owl on that Mac and start owl-dev there.
#
#   tools/drive.sh              build tools/.build/OwlDrive.app
#   tools/drive.sh HOST         and install it and /Applications/owl-dev.app
#                               (run ./build.sh first) on HOST over ssh
#
# HOST must be a Mac with someone logged in and no one using it: OwlDrive's
# plans are real mouse and keyboard input. Both apps need their grants on
# that Mac, given once by a person (Screen Sharing is enough): owl-dev
# Accessibility, Microphone and Screen Recording; OwlDrive Accessibility and
# Screen Recording.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/tools/.build/OwlDrive.app"
HOST="${1:-}"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
xcrun swiftc -O -target arm64-apple-macos26.0 -o "$OUT/Contents/MacOS/OwlDrive" "$HERE/tools/drive.swift"
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.owl.drive</string>
  <key>CFBundleName</key><string>OwlDrive</string>
  <key>CFBundleExecutable</key><string>OwlDrive</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2; exit}' || true)"
codesign --force --options runtime --sign "${IDENTITY:--}" "$OUT"
echo "==> built $OUT"
[ -n "$HOST" ] || exit 0

DEV="/Applications/owl-dev.app"
[ -d "$DEV" ] || { echo "no $DEV here; run ./build.sh first" >&2; exit 1; }
# Quit owl-dev there by its exact command line (the app, never an owl-dev
# command someone is running), then replace both apps and start owl-dev.
ssh "$HOST" 'pid=$(pgrep -f "^/Applications/owl-dev.app/Contents/MacOS/owl-dev$" || true)
    if [ -n "$pid" ]; then kill -TERM $pid; for _ in $(seq 1 50); do kill -0 $pid 2>/dev/null || break; sleep 0.1; done; fi'
/opt/homebrew/bin/rsync -a --delete "$DEV/" "${HOST}:/Applications/owl-dev.app/"
/opt/homebrew/bin/rsync -a --delete "$OUT/" "${HOST}:/Applications/OwlDrive.app/"
ssh "$HOST" 'mkdir -p ~/.local/bin && ln -sf /Applications/owl-dev.app/Contents/MacOS/owl-dev ~/.local/bin/owl-dev && open /Applications/owl-dev.app'
echo "==> owl-dev and OwlDrive are on $HOST; owl-dev is running there"
