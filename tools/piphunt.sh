#!/bin/bash
# Hunt the intermittent black-PiP bug with an objective oracle.
#
# Auto-PiP (the home-swipe path) cannot be driven from automation -- wda/deactivateApp, a real HID
# home press and a genuine app switch all leave possible=0 at background. So PiP is started through
# YouTube's own in-app entry point via libreyt://pip (see ytlStartPiPNow), which works every time.
#
# The oracle is tools/blackcheck.py: it crops the band between the PiP transport buttons and the
# scrubber and calls it BLACK only when that band is both dark AND flat. Variance matters -- a dark
# scene is not a dead layer, and a brightness-only check flags every night shot.
#
#   tools/piphunt.sh [cycles]     default 20
#
# Device must be UNLOCKED. Screen lock is deliberately not exercised: unlocking needs the user's
# passcode and a locked device refuses every launch (FBSOpenApplication "RequestDenied ... Locked").
set -uo pipefail
D="${DEVICE:-00008160-0012081E1EA0000A}"
B="${BUNDLE:-com.google.ios.youtube.9MLP9HR9UP.5JGF8REP89}"
CYCLES="${1:-20}"
OUT="${OUT:-/tmp/piphunt}"; mkdir -p "$OUT"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
VIDS=(dQw4w9WgXcQ kJQP7kiw5Fk 9bZkp7q19f0 jNQXAC9IVRw)
DC=(xcrun devicectl --quiet)

put() { "${DC[@]}" device copy to   --device "$D" --domain-type appDataContainer --domain-identifier "$B" --user mobile --source "$1" --destination "$2" >/dev/null 2>&1; }
get() { rm -f "$2"; "${DC[@]}" device copy from --device "$D" --domain-type appDataContainer --domain-identifier "$B" --user mobile --source "$1" --destination "$2" >/dev/null 2>&1; }
openu(){ xcrun devicectl device process launch --device "$D" --payload-url "$1" --activate "$B" >/dev/null 2>&1; }
shot() { curl -s -m 20 http://127.0.0.1:8100/screenshot 2>/dev/null \
          | python3 -Ic "import sys,json,base64;open('$OUT/$1.png','wb').write(base64.b64decode(json.load(sys.stdin)['value']))" 2>/dev/null; }

: > "$OUT/empty.txt"
put "$OUT/empty.txt" Documents/YTLitePiPLog.txt || { echo "!! device unreachable or LOCKED"; exit 1; }

black=0
for i in $(seq 1 "$CYCLES"); do
  V="${VIDS[$(( (i-1) % ${#VIDS[@]} ))]}"
  # Fresh process every other cycle: the one black capture so far followed a cold start, so make
  # sure cold starts are actually represented instead of only testing a warm, settled player.
  if [ $(( i % 2 )) -eq 1 ]; then
    xcrun devicectl device process terminate --device "$D" --bundle-identifier "$B" >/dev/null 2>&1
    sleep 2
  fi
  openu "libreyt://watch?v=$V"; sleep 13
  openu "libreyt://pip";        sleep 4
  shot "h${i}_${V}"
  if python3 -I "$REPO/tools/blackcheck.py" "$OUT/h${i}_${V}.png" 2>/dev/null; then
    black=$((black+1)); echo "    ^^ cycle $i video $V  <<< BLACK"
  fi
done

get Documents/YTLitePiPLog.txt "$OUT/pip.log"
echo
echo "==> $black / $CYCLES cycles BLACK      log: $OUT/pip.log"
