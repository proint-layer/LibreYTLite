#!/bin/bash
# Flag-crash sweep harness. Drives a FLAG_DEBUG build on a tethered device and reports which
# settings flags reach a known crash hazard (a delayed performSelector: whose selector is gone,
# or a KVC poke at an ivar YouTube renamed). See Utils/YTLFlagDiag.h for the two crash families.
#
#   tools/flagsweep.sh allon                 one launch, every BOOL on  (fast path -- start here)
#   tools/flagsweep.sh only <key> [<key>...] one launch per key, isolated
#   tools/flagsweep.sh sweep                 one launch per key, ALL keys (slow: ~100 launches)
#   tools/flagsweep.sh pull                  just fetch the current on-device report
#
# Env: DEVICE (udid), BUNDLE (app id), VIDEO (video id to open), DWELL (seconds per launch).
#
# Why a control FILE and not NSUserDefaults: cfprefsd caches preference domains, so a plist
# pushed from the host while the app is dead can be served stale on the next launch. The tweak
# reads this file itself, so what we write is what it sees.
set -uo pipefail

DEVICE="${DEVICE:-00008160-0012081E1EA0000A}"
BUNDLE="${BUNDLE:-com.google.ios.youtube.9MLP9HR9UP}"
VIDEO="${VIDEO:-dQw4w9WgXcQ}"
DWELL="${DWELL:-12}"
OUT="${OUT:-$(mktemp -d)}"
DC=(xcrun devicectl --quiet)

mkdir -p "$OUT"
say() { printf '%s\n' "$*" >&2; }

dev_put() { # <localfile> <container-relative-path>
  "${DC[@]}" device copy to --device "$DEVICE" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE" --user mobile --source "$1" --destination "$2" >/dev/null 2>&1
}
dev_get() { # <container-relative-path> <localfile>
  "${DC[@]}" device copy from --device "$DEVICE" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE" --user mobile --source "$1" --destination "$2" >/dev/null 2>&1
}
# The stock YouTube app may also be installed, and its executable path has the same
# .../YouTube.app/YouTube shape as ours -- matching on that alone reports the wrong process as
# "alive". Pin to OUR install directory instead.
APP_PATH=""
app_path() {
  if [ -z "$APP_PATH" ]; then
    # The table output has no path column; the JSON does.
    APP_PATH=$(xcrun devicectl device info apps --device "$DEVICE" --bundle-id "$BUNDLE" \
      --json-output /dev/stdout 2>/dev/null \
      | sed -n 's|.*"url"[^"]*"file://\(/private/var/containers/Bundle/Application/[^"]*\)/".*|\1|p' | head -1)
  fi
  printf '%s' "$APP_PATH"
}
app_running() {
  local path; path=$(app_path); [ -n "$path" ] || return 1
  xcrun devicectl device info processes --device "$DEVICE" --search "$path" 2>/dev/null \
    | grep -q "$path/"
}
app_kill() {
  local path pid; path=$(app_path)
  if [ -n "$path" ]; then
    pid=$(xcrun devicectl device info processes --device "$DEVICE" --search "$path" 2>/dev/null \
          | awk -v pfx="$path/" 'index($2, pfx)==1 {print $1; exit}')
    [ -n "${pid:-}" ] && "${DC[@]}" device process signal --device "$DEVICE" --pid "$pid" --signal SIGKILL >/dev/null 2>&1
  fi
  sleep 1
}

# One launch under a given control file. Echoes a one-line verdict.
run_case() { # <label> <control-file-contents>
  local label="$1" ctl="$2"
  printf '%s\n' "$ctl" > "$OUT/YTLSweep.txt"
  : > "$OUT/empty.log"

  app_kill
  dev_put "$OUT/YTLSweep.txt" "Documents/YTLSweep.txt"
  dev_put "$OUT/empty.log"    "Documents/YTLFlagDiag.log"   # reset the report

  "${DC[@]}" device process launch --device "$DEVICE" --terminate-existing "$BUNDLE" >/dev/null 2>&1
  sleep "$DWELL"

  local alive="alive"; app_running || alive="DEAD"
  local log="$OUT/report_$label.log"
  dev_get "Documents/YTLFlagDiag.log" "$log" || : > "$log"
  # NB: `grep -c` already prints 0 when there are no matches *and* exits 1 -- an `|| echo 0`
  # fallback here would append a second 0 and corrupt the count.
  local risks; risks=$(grep -c FLAGRISK "$log" 2>/dev/null); risks=${risks:-0}
  say "  [$label] $alive  risks=$risks"
  grep FLAGRISK "$log" 2>/dev/null | sed 's/^/      /' >&2
  printf '%s\t%s\t%s\t%s\n' "$label" "$alive" "$risks" "$log"
}

all_keys() {
  grep -ohE 'ytl(Bool|Int)\(@"[A-Za-z0-9_]+"' "$(dirname "$0")/.."/*.x \
    | grep -oE '"[A-Za-z0-9_]+"' | tr -d '"' | sort -u
}

# Integer flags must be forced off their no-op default or their gated code never runs.
INTS='int:wiFiQualityIndex=2
int:cellQualityIndex=2
int:autoSpeedIndex=1
int:speedIndex=5
int:pivotIndex=1'

case "${1:-allon}" in
  allon)
    say "== all-on pass (bundle=$BUNDLE device=$DEVICE) =="
    # shortsOnlyMode is excluded here: it hides the pivot bar and forces the Shorts tab, which
    # would stop the watch-page navigation that exercises the player hooks. It gets its own run.
    run_case allon "all=on
off=shortsOnlyMode
$INTS
label=all-on"
    run_case shortsonly "all=off
on=shortsOnlyMode
label=shorts-only"
    ;;
  only)
    shift; say "== isolating $# key(s) =="
    for k in "$@"; do run_case "$k" "all=off
on=$k
$INTS
label=only-$k"; done
    ;;
  sweep)
    say "== full sweep (slow) =="
    for k in $(all_keys); do run_case "$k" "all=off
on=$k
$INTS
label=only-$k"; done
    ;;
  manual)
    # Launch-only coverage can't reach the player, menus or settings UI -- devicectl cannot
    # synthesise touches. Arm every flag, then let a human drive; the trace dedupes per site,
    # so a few minutes of ordinary use enumerates far more than any scripted launch.
    say "== manual mode: all flags on, app launched -- now exercise the UI, then: $0 pull =="
    printf 'all=on\noff=shortsOnlyMode\n%s\nlabel=manual\n' "$INTS" > "$OUT/YTLSweep.txt"
    : > "$OUT/empty.log"
    app_kill
    dev_put "$OUT/YTLSweep.txt" "Documents/YTLSweep.txt"
    dev_put "$OUT/empty.log"    "Documents/YTLFlagDiag.log"
    "${DC[@]}" device process launch --device "$DEVICE" --terminate-existing "$BUNDLE" >/dev/null 2>&1
    say "   armed. OUT=$OUT"
    ;;
  pull)
    dev_get "Documents/YTLFlagDiag.log" "$OUT/report.log" && cat "$OUT/report.log"
    ;;
  *) say "unknown mode: $1"; exit 2 ;;
esac
say ""
say "artifacts: $OUT"
