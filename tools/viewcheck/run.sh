#!/bin/bash
# tools/viewcheck/run.sh <session id> [light|dark]
#
# Render the sessions window's panes, the script laid out flat, the sidebar
# rows, the picture viewer and Settings for one session, to PNGs in a new
# folder (printed at the end). Reads a backup of the development copy's
# catalog (CATALOG= to read another), never the catalog itself.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ID="${1:?usage: run.sh <session id> [light|dark]}"
MODE="${2:-light}"
CATALOG="${CATALOG:-$HOME/Library/Application Support/car-dev/car.sqlite}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/viewcheck.XXXXXX")"

# The app's sources, all but its main.swift, into Sources/viewcheck/app
# (not tracked), with the views the check reaches into opened up.
APP="$HERE/Sources/viewcheck/app"
rm -rf "$APP" && mkdir -p "$APP"
find "$HERE/../../App" -name '*.swift' ! -name 'main.swift' -exec cp {} "$APP/" \;
sed -i '' 's/^private struct/struct/' "$APP/ScriptView.swift" "$APP/Sidebar.swift"

mkdir -p "$WORK/root" "$WORK/out"
sqlite3 "$CATALOG" ".backup '$WORK/root/car.sqlite'"
END_MS=$(sqlite3 "$WORK/root/car.sqlite" "SELECT MAX(t) FROM events WHERE session = '$ID'")
swift build --package-path "$HERE" -q
CAR_ROOT="$WORK/root" END_MS="$END_MS" "$HERE/.build/debug/viewcheck" "$WORK/out" "$ID" "$MODE" 2>&1 | tee "$WORK/log"
echo "pictures in $WORK/out"
# AppKit says so when the table is changed while it lays itself out, which
# is how the script hung.
if grep -q "reentrant operation" "$WORK/log"; then
    echo "FAILED: the table was changed in the middle of its own layout (see above)" >&2
    exit 1
fi
