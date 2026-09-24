#!/bin/bash
# Run car's live test (tools/live-test.txt, or another plan) on HOST with
# CarDrive, then bring back its pictures and the timelines of the sessions it
# made. Put the apps there first with tools/drive.sh HOST.
#
#   tools/live-test.sh HOST [PLAN]
#
# The sessions it makes stay on HOST under car-dev's sessions; they are
# recordings of that room, so delete them when done (the output says which).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${1:?usage: tools/live-test.sh HOST [PLAN]}"
PLAN="${2:-$HERE/tools/live-test.txt}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOCAL="$HERE/tools/.build/live/$STAMP"
REMOTE="/tmp/car-live-$STAMP"
mkdir -p "$LOCAL"

before="$(ssh "$HOST" '~/.local/bin/car-dev sessions' | awk '{print $1}')"
ssh "$HOST" "mkdir -p $REMOTE" && scp -q "$PLAN" "${HOST}:$REMOTE/plan.txt"
echo "==> playing $(basename "$PLAN") on $HOST"
ssh "$HOST" "open -W -n /Applications/CarDrive.app --args $REMOTE/plan.txt $REMOTE/out"
# `open -W` can return before a quick app is gone; wait for the plan's end.
ssh "$HOST" "for _ in \$(seq 1 300); do grep -q '  done$' $REMOTE/out/log.txt 2>/dev/null && break; sleep 1; done"
/opt/homebrew/bin/rsync -a "${HOST}:$REMOTE/out/" "$LOCAL/"
ssh "$HOST" "rm -rf $REMOTE"
cat "$LOCAL/log.txt"

after="$(ssh "$HOST" '~/.local/bin/car-dev sessions' | awk '{print $1}')"
for id in $(comm -13 <(echo "$before" | sort) <(echo "$after" | sort)); do
    echo; echo "==> session $id"
    ssh "$HOST" "~/.local/bin/car-dev session $id" | tee "$LOCAL/$id.md"
    mkdir -p "$LOCAL/$id"
    ssh "$HOST" "cd \"\$HOME/Library/Application Support/car-dev/sessions/$id\" && tar -cf - shots events.jsonl meta.json" \
        | tar -xf - -C "$LOCAL/$id"
done
echo; echo "==> pictures and timelines in $LOCAL"
