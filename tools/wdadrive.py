#!/usr/bin/env python3
"""
Coverage-driven UI sweep for LibreYTLite, driven by WebDriverAgent.

WHY THIS EXISTS
---------------
`tools/flagsweep.sh allon` can only *launch* the app. Launch-only reaches ~55 of the 97
flag-gated branches; everything behind the watch page, the kebab menu, Shorts, share and the
settings UI is simply never evaluated, so a clean sweep proved much less than it looked like.
This drives the real UI and measures what it reached.

THE METRIC
----------
The FLAG_DEBUG build emits `FLAGREAD <key>=<value>` on first read of every settings key, into
Documents/YTLFlagDiag.log. So coverage is *measured, not estimated*: distinct FLAGREAD keys over
the 97 keys that appear in a flag-gated branch. A journey that doesn't move the number reached
nothing new, however good the screenshots looked.

Caveat worth keeping in mind: FLAGREAD proves a branch was *evaluated*, not that it did the right
thing. It finds untested surface. FLAGRISK lines and crashes are the actual fault signals.

PROFILES, AND WHY ONE all=on RUN IS NOT ENOUGH
----------------------------------------------
`all=on` forces every bool YES, which is what unblocks *nested* gates -- `24hrFormat` is only read
inside addEndTime(), which early-returns unless `videoEndTime` is on. But all=on also switches on
every flag whose job is to REMOVE UI: hideShorts hides Shorts, removeShareMenu removes the share
row, removeSubscriptions deletes the tab. Those make the very surfaces we need unreachable.
So we run several profiles and take the UNION. `off=` beats the `all=on` baseline in the control
file, which is exactly the lever that makes this work.
"""
import json, subprocess, sys, time, urllib.request, urllib.error, os, re

WDA     = os.environ.get("WDA", "http://127.0.0.1:8100")
DEVICE  = os.environ.get("DEVICE", "00008160-0012081E1EA0000A")
BUNDLE  = os.environ.get("BUNDLE", "com.google.ios.youtube.9MLP9HR9UP.5JGF8REP89")
OUT     = os.environ.get("OUT", "/tmp/wdasweep")
LOGNAME = "YTLFlagDiag.log"
SWEEPF  = "YTLSweep.txt"

os.makedirs(OUT, exist_ok=True)

# ---------------------------------------------------------------- WDA plumbing
def rq(method, path, body=None, timeout=60):
    url = WDA + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        try:    return json.loads(e.read().decode())
        except Exception: return {"value": {"error": "http %s" % e.code}}
    except Exception as e:
        return {"value": {"error": str(e)}}

class S:
    def __init__(self):
        self.sid = None
    def start(self):
        r = rq("POST", "/session", {"capabilities": {"alwaysMatch": {
            "bundleId": BUNDLE, "shouldWaitForQuiescence": False}}}, timeout=120)
        self.sid = (r.get("value") or {}).get("sessionId")
        return self.sid
    def stop(self):
        if self.sid: rq("DELETE", "/session/" + self.sid)
        self.sid = None
    def p(self, path): return "/session/%s%s" % (self.sid, path)
    def source(self):
        return rq("GET", self.p("/source?format=json"), timeout=90).get("value")
    def find(self, using, value):
        r = rq("POST", self.p("/element"), {"using": using, "value": value}, timeout=30)
        v = r.get("value")
        if isinstance(v, dict) and ("ELEMENT" in v or "element-6066-11e4-a52e-4f735466cecf" in v):
            return v.get("ELEMENT") or v.get("element-6066-11e4-a52e-4f735466cecf")
        return None
    def click(self, eid):
        return rq("POST", self.p("/element/%s/click" % eid), {}, timeout=30)
    def tap(self, x, y):
        return rq("POST", self.p("/wda/tap"), {"x": x, "y": y}, timeout=30)
    def swipe(self, x1, y1, x2, y2, dur=0.35):
        return rq("POST", self.p("/wda/dragfromtoforduration"),
                  {"fromX": x1, "fromY": y1, "toX": x2, "toY": y2, "duration": dur}, timeout=40)
    def app_terminate(self):
        return rq("POST", self.p("/wda/apps/terminate"), {"bundleId": BUNDLE}, timeout=40)
    def app_launch(self):
        return rq("POST", self.p("/wda/apps/launch"), {"bundleId": BUNDLE}, timeout=90)
    def background(self, secs):
        return rq("POST", self.p("/wda/deactivateApp"), {"duration": secs}, timeout=secs + 60)
    def shot(self, name):
        r = rq("GET", "/screenshot", timeout=60)
        v = r.get("value")
        if isinstance(v, str):
            import base64
            open(os.path.join(OUT, name + ".png"), "wb").write(base64.b64decode(v))

# ------------------------------------------------------------ device file I/O
def dev_put(local, rel):
    return subprocess.run(["xcrun", "devicectl", "--quiet", "device", "copy", "to",
        "--device", DEVICE, "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE,
        "--user", "mobile", "--source", local, "--destination", rel],
        capture_output=True).returncode == 0

def dev_get(rel, local):
    return subprocess.run(["xcrun", "devicectl", "--quiet", "device", "copy", "from",
        "--device", DEVICE, "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE,
        "--user", "mobile", "--source", rel, "--destination", local],
        capture_output=True).returncode == 0

def kill_app():
    subprocess.run(["xcrun", "devicectl", "device", "process", "terminate",
                    "--device", DEVICE, "--bundle-identifier", BUNDLE],
                   capture_output=True)

def set_profile(text):
    f = os.path.join(OUT, SWEEPF)
    open(f, "w").write(text + "\n")
    return dev_put(f, "Documents/" + SWEEPF)

PIPLOG = "YTLitePiPLog.txt"

def clear_log():
    f = os.path.join(OUT, "empty.log")
    open(f, "w").write("")
    ok = dev_put(f, "Documents/" + LOGNAME)
    dev_put(f, "Documents/" + PIPLOG)   # same for the PiP log, so each profile stands alone
    return ok

def pull_piplog(tag):
    dst = os.path.join(OUT, "pip_%s.log" % tag)
    if os.path.exists(dst): os.remove(dst)
    if not dev_get("Documents/" + PIPLOG, dst) or not os.path.exists(dst):
        return ""
    return open(dst, errors="replace").read()

def pull_log(tag):
    # devicectl's --destination must be a FILE path here. Passing a directory silently
    # copies nothing and the harness reports 0 flags for a run that actually worked --
    # which looks exactly like "the build is broken". Keep it a file.
    dst = os.path.join(OUT, "raw_%s.log" % tag)
    if os.path.exists(dst):
        os.remove(dst)
    if not dev_get("Documents/" + LOGNAME, dst) or not os.path.exists(dst):
        return ""
    return open(dst, errors="replace").read()

# -------------------------------------------------------------- tree helpers
def flatten(node, out=None, depth=0):
    if out is None: out = []
    if not isinstance(node, dict): return out
    out.append((depth, node.get("type", ""), node.get("name") or "",
                node.get("label") or "", node.get("rect") or {}))
    for c in (node.get("children") or []):
        flatten(c, out, depth + 1)
    return out

def dump_tree(s, tag):
    src = s.source()
    if not src: return []
    flat = flatten(src)
    with open(os.path.join(OUT, "tree_%s.txt" % tag), "w") as fh:
        for d, t, n, l, r in flat:
            fh.write("%s%s | name=%s | label=%s | %s\n" % ("  " * min(d, 10), t, n[:70], l[:70], r))
    return flat

# ============================================================================
# TEST CASES
#
# Each journey exists to reach ONE flag cluster that launch-only never evaluates.
# Selectors are the app's real accessibility ids, read off a live tree (see
# `wdadrive.py explore`) -- not guessed. The ones that matter:
#
#   id.ui.pivotbar.FEwhat_to_watch.button   Home tab
#   id.ui.pivotbar.FEshorts.button          Shorts tab
#   id.ui.pivotbar.FElibrary.button         You tab
#   eml.overflow_button                     kebab / "Action menu"
#   id.ui.navigation.search.button          search
#
# The watch page is entered by URL, not by tapping the feed: the feed's top slot
# is often a Shorts shelf (`short-item-index-N`) with no duration label, so a
# heuristic "find a video cell" tap opens a Short instead of the watch page and
# the whole 36-flag player cluster silently stays uncovered. `libreyt://watch?v=`
# drives the universal-link path straight to the player, every time.
# ============================================================================

HOME_BTN   = "id.ui.pivotbar.FEwhat_to_watch.button"
SHORTS_BTN = "id.ui.pivotbar.FEshorts.button"
YOU_BTN    = "id.ui.pivotbar.FElibrary.button"
KEBAB      = "eml.overflow_button"
TEST_VIDEO = os.environ.get("VIDEO", "dQw4w9WgXcQ")

def step(s, label, fn):
    t0 = time.time()
    try:
        ok = fn()
    except Exception as e:
        ok = "EXC %s" % e
    print("      - %-34s %s  (%.1fs)" % (label, ok, time.time() - t0), flush=True)
    return ok

def tap_name(s, name, timeout=8):
    end = time.time() + timeout
    while time.time() < end:
        eid = s.find("name", name)
        if eid:
            s.click(eid); return True
        time.sleep(0.6)
    return False

def tap_pred(s, pred, timeout=8):
    end = time.time() + timeout
    while time.time() < end:
        eid = s.find("predicate string", pred)
        if eid:
            s.click(eid); return True
        time.sleep(0.6)
    return False

def open_video(vid=None):
    """Deterministic watch-page entry via the tweak's own libreyt:// scheme."""
    url = "libreyt://watch?v=%s" % (vid or TEST_VIDEO)
    r = subprocess.run(["xcrun", "devicectl", "device", "process", "launch",
                        "--device", DEVICE, "--payload-url", url, "--activate", BUNDLE],
                       capture_output=True, text=True)
    return "launched" if r.returncode == 0 else "fail:%s" % r.stderr.strip()[:60]

def sleep_(n):
    return lambda: (time.sleep(n), True)[1]

def reset(s):
    """Return the app to a known Home state before a journey.

    Without this the journeys are order-dependent: `watch` leaves a player up and
    `pip` leaves a miniplayer, and the pivot bar is then not in the tree -- so the
    Shorts/You/Subscriptions taps that follow all fail and their whole flag clusters
    go uncovered. That looks like "those hooks are dead" when it is really just the
    harness tapping at a screen that moved. Terminate + relaunch is the cheap fix;
    it also gives every journey its own RUNSTART, which makes the log readable."""
    s.app_terminate(); time.sleep(1.5)
    s.app_launch();    time.sleep(6)
    for _ in range(3):
        if tap_name(s, HOME_BTN, 4):
            time.sleep(2.5)
            return True
        time.sleep(2)
    return False


def j_feed(s):
    """FEED + TAB BAR + FEED HEADER + launch cold-config. ~26 flags."""
    step(s, "reset to Home", lambda: reset(s))
    step(s, "go Home", lambda: tap_name(s, HOME_BTN, 8))
    step(s, "settle", sleep_(4))
    for i in range(3):
        step(s, "scroll feed %d" % (i + 1), lambda: s.swipe(200, 620, 200, 240, 0.30) is not None)
        step(s, "dwell", sleep_(2))
    step(s, "scroll back up", lambda: s.swipe(200, 300, 200, 660, 0.30) is not None)
    step(s, "visit Subscriptions", lambda: tap_name(s, "id.ui.pivotbar.FEsubscriptions.button", 6))
    step(s, "dwell", sleep_(3))
    step(s, "back Home", lambda: tap_name(s, HOME_BTN, 6))
    step(s, "shot", lambda: (s.shot("feed"), True)[1])

def j_watch(s):
    """PLAYER / WATCH -- the biggest uncovered cluster (36 flags).
    Targets: videoEndTime -> 24hrFormat, redProgressBar, noWatermarks,
    wiFiQualityIndex/autoQuality, noPlayerRemix/Clip/DownloadButton (via the
    scrollable action bar), dontSnapToChapter, noTwoFingerSnapToChapter."""
    step(s, "reset to Home", lambda: reset(s))
    step(s, "open video by URL", lambda: open_video())
    step(s, "play 15s", sleep_(15))
    step(s, "tap player (overlay)", lambda: s.tap(200, 150) is not None)
    step(s, "dwell for end-time tick", sleep_(6))
    step(s, "scroll action bar", lambda: s.swipe(330, 300, 70, 300, 0.35) is not None)
    step(s, "dwell", sleep_(3))
    step(s, "scrub (snap-to-chapter)", lambda: s.swipe(120, 232, 300, 232, 0.5) is not None)
    step(s, "dwell", sleep_(4))
    step(s, "scroll to comments", lambda: s.swipe(200, 620, 200, 300, 0.30) is not None)
    step(s, "dwell", sleep_(4))
    step(s, "shot", lambda: (s.shot("watch"), True)[1])

def j_fullscreen(s):
    """portraitFullscreen / allowedFullScreenOrientations, and the noFeedRotation
    interaction (the two are opposite in spirit -- verify fullscreen still works)."""
    step(s, "open video", lambda: open_video())
    step(s, "dwell", sleep_(10))
    step(s, "tap player", lambda: s.tap(200, 150) is not None)
    step(s, "dwell", sleep_(2))
    step(s, "fullscreen button", lambda: tap_pred(s,
        "label CONTAINS[c] 'full screen' OR label CONTAINS[c] 'fullscreen'", 6))
    step(s, "dwell", sleep_(6))
    step(s, "shot", lambda: (s.shot("fullscreen"), True)[1])
    step(s, "exit fullscreen", lambda: tap_pred(s, "label CONTAINS[c] 'exit full'", 5)
         or s.tap(30, 40) is not None)
    step(s, "dwell", sleep_(3))

def j_pip(s):
    """PIP -- the user-reported bug, and the region the last sweep could not see at all.
    `ytlPipRearm` was read ZERO times previously, so the re-entry fix was never
    exercised. background(N) is the automated equivalent of the home swipe that
    triggers auto-PiP; returning is the 'come back and retry' the fix automates.
    Three cycles because the reported failure is intermittent and shows on re-entry,
    not the first entry."""
    step(s, "reset to Home", lambda: reset(s))
    step(s, "ensure video playing", lambda: open_video())
    step(s, "play 10s", sleep_(10))
    for i in (1, 2, 3):
        step(s, "background 8s (cycle %d)" % i, lambda: s.background(8) is not None)
        step(s, "settle after return", sleep_(5))
        step(s, "shot", lambda: (s.shot("pip_cycle%d" % i), True)[1])

def j_menu(s):
    """MENU (kebab sheet) -- 8 remove*Menu flags, reached from a feed cell's ... button."""
    step(s, "reset to Home", lambda: reset(s))
    step(s, "go Home", lambda: tap_name(s, HOME_BTN, 8))
    step(s, "settle", sleep_(4))
    step(s, "tap kebab", lambda: tap_name(s, KEBAB, 8))
    step(s, "dwell for sheet", sleep_(4))
    step(s, "shot", lambda: (s.shot("menu"), True)[1])
    step(s, "dismiss", lambda: s.swipe(200, 700, 200, 860, 0.3) is not None)
    step(s, "dwell", sleep_(2))

def j_share(s):
    """SHARE -- noShareChunk (the si= strip, incl. the _UIConcretePasteboard setters)."""
    step(s, "reset to Home", lambda: reset(s))
    step(s, "open video", lambda: open_video())
    step(s, "dwell", sleep_(8))
    step(s, "tap Share", lambda: tap_pred(s, "label CONTAINS[c] 'share'", 8))
    step(s, "dwell for sheet", sleep_(5))
    step(s, "shot", lambda: (s.shot("share_sheet"), True)[1])
    step(s, "tap Copy link", lambda: tap_pred(s, "label CONTAINS[c] 'copy link'", 6))
    step(s, "dwell", sleep_(3))
    step(s, "shot", lambda: (s.shot("share_after"), True)[1])
    step(s, "dismiss", lambda: tap_pred(s, "label CONTAINS[c] 'close' OR label CONTAINS[c] 'cancel'", 4)
         or s.swipe(200, 700, 200, 860, 0.3) is not None)

def j_shorts(s):
    """SHORTS -- 9 flags incl. shortsProgress, hideShortsActionBar, pinchToFullscreenShorts.
    Needs hideShorts/removeShorts/shortsOnlyMode forced OFF (the `nav` profile)."""
    step(s, "reset to Home", lambda: reset(s))
    step(s, "tap Shorts tab", lambda: tap_name(s, SHORTS_BTN, 10))
    step(s, "dwell", sleep_(9))
    for i in (1, 2):
        step(s, "swipe to next short %d" % i, lambda: s.swipe(200, 640, 200, 180, 0.25) is not None)
        step(s, "dwell", sleep_(7))
    step(s, "shot", lambda: (s.shot("shorts"), True)[1])
    step(s, "leave Shorts", lambda: tap_name(s, HOME_BTN, 6))

def j_settings(s):
    """SETTINGS UI -- noHints, plus the five Settings.x KVC sites that were unguarded
    (_orderedCategories, _touchFeedbackController, _switch, _settingsViewControllerDelegate).
    Those run in -layoutSubviews for every cell, so scrolling the list is the point."""
    step(s, "reset to Home", lambda: reset(s))
    step(s, "tap You tab", lambda: tap_name(s, YOU_BTN, 8))
    step(s, "dwell", sleep_(4))
    step(s, "tap Settings", lambda: tap_pred(s, "label CONTAINS[c] 'settings'", 8))
    step(s, "dwell", sleep_(5))
    step(s, "shot", lambda: (s.shot("settings"), True)[1])
    step(s, "open LibreYTLite", lambda: tap_pred(s,
        "label CONTAINS[c] 'ytlite' OR label CONTAINS[c] 'libreyt'", 8))
    step(s, "dwell", sleep_(4))
    for i in range(3):
        step(s, "scroll settings %d" % (i + 1), lambda: s.swipe(200, 620, 200, 260, 0.30) is not None)
        step(s, "dwell", sleep_(2))
    step(s, "shot", lambda: (s.shot("settings_ytlite"), True)[1])
    step(s, "back Home", lambda: tap_name(s, HOME_BTN, 6))

JOURNEYS = {
    "feed": j_feed, "watch": j_watch, "fullscreen": j_fullscreen, "pip": j_pip,
    "menu": j_menu, "share": j_share, "shorts": j_shorts, "settings": j_settings,
}

# Flags whose whole job is to REMOVE navigation UI. A pure all=on run switches these on
# and then cannot reach Shorts, the share row or half the tab bar -- so the deep surfaces
# go uncovered precisely because coverage was maximised. Forced off in the `nav` profile;
# their on-branch is still covered by the `allon` profile at launch.
NAV_BLOCKERS = ",".join([
    "hideShorts", "removeShorts", "shortsOnlyMode", "removeSubscriptions", "removeLibrary",
    "removeUploads", "reExplore", "addExplore", "noSearchButton", "removeShareMenu",
    "noSubbar", "removeDownloadMenu", "removeSaveToPlaylistMenu", "removePlayNext",
    "removeNotInterestedMenu", "removeDontRecommendMenu", "removeReportMenu",
])

PROFILES = {
    "allon": "all=on\nlabel=allon",
    # --- PiP isolation pair -------------------------------------------------
    # Under all=on the PiP log shows PiP never even becomes possible: a `deactivate`
    # lands just before every background and `APP -> background` reports possible=0.
    # backgroundPlayback is the obvious suspect -- with background AUDIO enabled
    # YouTube has no reason to keep a PiP controller armed. These two profiles differ
    # in exactly that one flag, so whichever way it falls the answer is attributable.
    "pipbg":   "all=off\non=pipReentryFix,pipDiagLog,backgroundPlayback\nlabel=pipbg",
    "pipnobg": "all=off\non=pipReentryFix,pipDiagLog\noff=backgroundPlayback\nlabel=pipnobg",
    "nav":   "all=on\noff=%s\nlabel=nav" % NAV_BLOCKERS,
    "off":   "all=off\nlabel=off",
}

PLAN = [
    ("nav",   ["feed", "watch", "fullscreen", "pip", "menu", "share", "shorts", "settings"]),
    ("allon", ["feed", "watch", "pip"]),
]

def flags_in_log(text):
    return set(re.findall(r"FLAGREAD ([A-Za-z0-9_]+)", text))

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "run"
    s = S()

    if cmd == "explore":
        if not s.start(): print("no session"); return 1
        time.sleep(4)
        flat = dump_tree(s, "explore")
        for d, t, n, l, r in flat:
            if (n or l):
                print("%s%-11s name=%-36s label=%-32s %s" % ("  " * min(d, 8), t, n[:36], l[:32], r))
        print("nodes:", len(flat))
        s.stop(); return 0

    allflags = set()
    af = os.environ.get("ALLFLAGS")
    if af and os.path.exists(af):
        allflags = set(x.strip() for x in open(af) if x.strip())

    only = os.environ.get("ONLY")
    plan = PLAN
    if only:
        prof, _, js = only.partition(":")
        plan = [(prof, js.split(",") if js else [j for _, jl in PLAN for j in jl])]

    union, per_profile, all_risks, all_pips = set(), {}, [], []
    for prof, journeys in plan:
        print("\n=== PROFILE %s === (%s)" % (prof, ", ".join(journeys)), flush=True)
        kill_app(); time.sleep(2)
        if not set_profile(PROFILES[prof]): print("  !! control file write FAILED")
        if not clear_log():                 print("  !! log clear FAILED")
        time.sleep(1)
        if not s.start():
            print("  !! session failed"); continue
        for jn in journeys:
            print("  -> journey %s" % jn, flush=True)
            try:
                JOURNEYS[jn](s)
            except Exception as e:
                print("     !! journey %s raised %s" % (jn, e))
        s.stop(); time.sleep(2)
        kill_app(); time.sleep(4)      # SUMMARY is written on background/terminate
        txt = pull_log(prof)
        open(os.path.join(OUT, "report_%s.log" % prof), "w").write(txt)
        got = flags_in_log(txt)
        per_profile[prof] = got
        union |= got
        risks = [l for l in txt.splitlines() if "FLAGRISK" in l]
        ptxt  = pull_piplog(prof)
        pips  = [l for l in ptxt.splitlines() if l.strip()]
        all_risks += risks; all_pips += pips
        print("  == %-6s flags=%-4d FLAGRISK=%-3d PIP-events=%d" % (prof, len(got), len(risks), len(pips)))

    print("\n================ COVERAGE ================")
    for p, g in per_profile.items():
        print("  %-8s %d" % (p, len(g)))
    if allflags:
        print("  UNION    %d / %d  (%.0f%%)" % (len(union & allflags), len(allflags),
                                                100.0 * len(union & allflags) / len(allflags)))
        print("\n  STILL UNCOVERED (%d):\n    %s" % (len(allflags - union),
              " ".join(sorted(allflags - union))))
    else:
        print("  UNION    %d" % len(union))
    print("\n  FLAGRISK lines: %d" % len(all_risks))
    for l in all_risks[:25]: print("    " + l.strip())
    print("\n  PIP events: %d" % len(all_pips))
    for l in all_pips[:60]: print("    " + l.strip())
    open(os.path.join(OUT, "union.flags"), "w").write("\n".join(sorted(union)))
    return 0

if __name__ == "__main__":
    sys.exit(main())
