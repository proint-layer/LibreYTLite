#!/bin/bash
# Reproduce the FROZEN-PiP bug by racing a PiP start against a cold display layer.
#
# THE OBSERVATION THIS IS BUILT ON (device log, 11-08 12:01:34, 1 of 18 sessions):
#
#   11:42:19  APP -> background                      (app sits idle 19 minutes)
#   12:01:32  APP -> foreground
#   12:01:33  willStart possible=1                   <- iOS says PiP is fine
#   12:01:34  didStart  ... hamReady=0 ...           <- the layer behind it is NOT ready
#   12:12:44  didStop                                <- 11 minutes of PiP
#
# hamReady=0 appeared in exactly ONE of 18 sessions, and that session is the one the user
# reported as "video froze but audio kept playing". The layer still held the frame from when the
# app was backgrounded, so the window showed a still picture while audio ran on its own path.
# Every other foreground in the log is followed ~18ms later by a recreateDisplayLayer; this one
# has none. So: pictureInPicturePossible goes 1 BEFORE the sample-buffer layer is ready to draw,
# and starting PiP inside that gap gets you a window with nothing feeding it.
#
# WHAT THIS SCRIPT DOES: plays a video, backgrounds the app for a soak, then force-starts PiP
# within a few hundred ms of the foreground -- a TIGHTER race than the 2.3s the user hit. It then
# reads hamReady straight out of the log. No screenshots and no WDA: the oracle that drove the
# earlier hunt could only recognise a BLACK frame, and a frozen frame is a normal bright picture,
# so it scored every freeze as "ok". The log field is the ground truth; a picture is not.
#
#   tools/pipcold.sh            # default soak sweep, 2 rounds
#   SOAKS="20 120" R=3 tools/pipcold.sh
#
# Device must be UNLOCKED. Nothing is ever written to the device log -- it is only copied off, so
# a repro captured here cannot be destroyed by the harness that found it.
set -uo pipefail
D="${DEVICE:-00008160-0012081E1EA0000A}"
B="${BUNDLE:-com.google.ios.youtube.9MLP9HR9UP.5JGF8REP89}"
O="${OTHER:-com.moffatman.chan}"
SOAKS="${SOAKS:-20 90 240}"
DELAYS="${DELAYS:-1.5}"
R="${R:-2}"
OUT="${OUT:-/tmp/pipcold}"; mkdir -p "$OUT"
VIDS=(dQw4w9WgXcQ kJQP7kiw5Fk 9bZkp7q19f0 jNQXAC9IVRw)
DC=(xcrun devicectl --quiet)

get()  { rm -f "$2"; "${DC[@]}" device copy from --device "$D" --domain-type appDataContainer \
           --domain-identifier "$B" --user mobile --source Documents/YTLitePiPLog.txt --destination "$2" >/dev/null 2>&1; }
openu(){ "${DC[@]}" device process launch --device "$D" --payload-url "$1" --activate "$B" >/dev/null 2>&1; }
app()  { "${DC[@]}" device process launch --device "$D" --activate "$1" >/dev/null 2>&1; }

get x "$OUT/base.log" || { echo "!! cannot read the device container -- is the phone UNLOCKED?"; exit 1; }
base=$(wc -l < "$OUT/base.log")
echo "baseline: $base log lines"

n=0; bad=0
for round in $(seq 1 "$R"); do
  for soak in $SOAKS; do
   for delay in $DELAYS; do
    n=$((n+1)); vid="${VIDS[$(( (n-1) % ${#VIDS[@]} ))]}"
    printf "\n--- #%d  soak=%ss  delay=%ss  vid=%s\n" "$n" "$soak" "$delay" "$vid"
    openu "libreyt://watch?v=$vid"; sleep 12      # play long enough for the layer to be genuinely ready
    app "$O"; echo "    backgrounded, soaking ${soak}s..."; sleep "$soak"
    # Foreground and PiP-start must be SEPARATE steps. Doing both in one libreyt://pip (which
    # activates the app as it delivers the URL) fires the request ~10ms after foreground, and iOS
    # silently drops it -- no willStart, no FAILED, nothing. The user's real repro started PiP
    # 1.4s after foreground, which is late enough to be accepted and still early enough that the
    # display layer has not finished becoming ready. That gap is the whole bug, so sweep it.
    app "$B"; sleep "$delay"
    openu "libreyt://pip"
    sleep 10
    get x "$OUT/now.log"
    new=$(( $(wc -l < "$OUT/now.log") - base ))
    tail -n "$new" "$OUT/now.log" > "$OUT/attempt-$n.log"
    base=$(wc -l < "$OUT/now.log")
    ready=$(grep -oE "didStart .*hamReady=[01]" "$OUT/attempt-$n.log" | grep -oE "hamReady=[01]" | tail -1)
    watch=$(grep -c "watch t+" "$OUT/attempt-$n.log")
    case "$ready" in
      hamReady=0) bad=$((bad+1)); echo "    *** REPRO: $ready  (watch samples: $watch)" ;;
      hamReady=1) echo "    ok: $ready  (watch samples: $watch)" ;;
      *)          echo "    no didStart this attempt -- PiP did not start" ;;
    esac
    grep -E "watch t\+.*(CHANGED|first)" "$OUT/attempt-$n.log" | sed 's/^/      /' | head -6
    app "$O"; sleep 2
   done
  done
done
echo; echo "==> hamReady=0 in $bad / $n attempts    per-attempt logs: $OUT/attempt-*.log"
