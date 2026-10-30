#!/bin/bash
# Hunt the intermittent black-PiP bug with an objective oracle.
#
# Auto-PiP (the home-swipe path) cannot be driven from automation -- wda/deactivateApp, a real HID
# home press and a genuine app switch all leave possible=0 at background. So PiP is started through
# YouTube's own in-app entry point via libreyt://pip (see ytlStartPiPNow), which works every time.
#
#   tools/piphunt.sh [cycles]          MODE=plain (default): fresh-ish player, PiP, check
#   MODE=renav tools/piphunt.sh [n]    reconstruct the one observed repro (see below)
#
# MODE=renav reproduces the conditions of the single black capture on 2026-10-30 14:37: a
# long-lived process that had already run 8 PiP cycles and 8 app-switch round trips, whose last
# action before the black window was OUR re-arm arming the controller
# ("after re-arm #1 possible=1"), followed by a libreyt://watch re-navigation and then a PiP start.
# The theory that motivates it: we arm a controller bound to the old layer, the navigation rebuilds
# the player, and PiP then starts on a stale binding -- window present, nothing feeding it.
# Plain cycling alone never reproduced it (0/10), nor re-navigation alone (0/20).
#
# Device must be UNLOCKED and WDA up. Screen lock is deliberately not exercised: unlocking needs
# the user's passcode and a locked device refuses every launch (FBSOpenApplication "...Locked").
set -uo pipefail
D="${DEVICE:-00008160-0012081E1EA0000A}"
B="${BUNDLE:-com.google.ios.youtube.9MLP9HR9UP.5JGF8REP89}"
O="${OTHER:-com.moffatman.chan}"
MODE="${MODE:-plain}"
N="${1:-20}"
OUT="${OUT:-/tmp/piphunt}"; mkdir -p "$OUT"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
VIDS=(dQw4w9WgXcQ kJQP7kiw5Fk 9bZkp7q19f0 jNQXAC9IVRw)
DC=(xcrun devicectl --quiet)

put()  { "${DC[@]}" device copy to   --device "$D" --domain-type appDataContainer --domain-identifier "$B" --user mobile --source "$1" --destination "$2" >/dev/null 2>&1; }
get()  { rm -f "$2"; "${DC[@]}" device copy from --device "$D" --domain-type appDataContainer --domain-identifier "$B" --user mobile --source "$1" --destination "$2" >/dev/null 2>&1; }
openu(){ xcrun devicectl device process launch --device "$D" --payload-url "$1" --activate "$B" >/dev/null 2>&1; }
app()  { xcrun devicectl device process launch --device "$D" --activate "$1" >/dev/null 2>&1; }
shot() { curl -s -m 20 http://127.0.0.1:8100/screenshot 2>/dev/null \
          | python3 -Ic "import sys,json,base64;open('$OUT/$1.png','wb').write(base64.b64decode(json.load(sys.stdin)['value']))" 2>/dev/null; }

curl -s -m 8 http://127.0.0.1:8100/status 2>/dev/null | grep -q '"ready" : true' \
  || { echo "!! WDA is not up -- every capture would be empty and the run would report a FALSE 0 BLACK"; exit 1; }
: > "$OUT/empty.txt"
put "$OUT/empty.txt" Documents/YTLitePiPLog.txt || { echo "!! device unreachable or LOCKED"; exit 1; }

black=0; checked=0
check() { # <name>
  shot "$1"
  python3 -I "$REPO/tools/blackcheck.py" "$OUT/$1.png"; rc=$?
  case $rc in
    0) black=$((black+1)); checked=$((checked+1)); echo "   ^^ $1 BLACK" ;;
    1) checked=$((checked+1)) ;;
    *) echo "!! unusable capture at $1 -- aborting rather than reporting a false negative"; finish; exit 1 ;;
  esac
}
finish() { get Documents/YTLitePiPLog.txt "$OUT/pip.log"; echo; echo "==> BLACK $black / $checked measured   log: $OUT/pip.log"; }

if [ "$MODE" = renav ]; then
  xcrun devicectl device process terminate --device "$D" --bundle-identifier "$B" >/dev/null 2>&1; sleep 2
  openu "libreyt://watch?v=${VIDS[0]}"; sleep 13
  for r in $(seq 1 "$N"); do
    for c in 1 2 3 4; do                      # build up in-process PiP state and fire re-arms
      openu "libreyt://pip"; sleep 3
      app "$O";  sleep 4                      # app switch kills in-app PiP and backgrounds us
      app "$B";  sleep 4                      # foreground -> ytlPipRearm runs
    done
    openu "libreyt://watch?v=${VIDS[$(( (r-1) % ${#VIDS[@]} ))]}"; sleep 12   # re-navigate
    openu "libreyt://pip"; sleep 4
    check "renav${r}"
  done
else
  for i in $(seq 1 "$N"); do
    V="${VIDS[$(( (i-1) % ${#VIDS[@]} ))]}"
    if [ $(( i % 2 )) -eq 1 ]; then
      xcrun devicectl device process terminate --device "$D" --bundle-identifier "$B" >/dev/null 2>&1; sleep 2
    fi
    openu "libreyt://watch?v=$V"; sleep 13
    openu "libreyt://pip";        sleep 4
    check "h${i}_${V}"
  done
fi
finish
