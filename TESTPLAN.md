# Coverage-driven UI test plan

For contributors touching a flag-gated hook in `YTLite.x` / `Settings.x`.

## Why this exists

`tools/flagsweep.sh allon` can only *launch* the app, and a launch evaluates a little over half
of the flag-gated branches. Everything behind the watch page, the kebab sheet, Shorts, share and
the settings screen is simply never reached, so a clean sweep proved far less than it appeared to.
AGENTS.md §8 is blunt about this: a hook that compiles is not a hook that works, and only an
on-device log proves one fired. This plan is how we get that log without a human tapping through
every surface by hand.

## The metric: measured, not estimated

A `FLAG_DEBUG` build emits `FLAGREAD <key>=<value>` on the first read of every settings key, into
`Documents/YTLFlagDiag.log`. So coverage is a count, not a judgement:

```
distinct FLAGREAD keys  /  97 keys that appear in a flag-gated branch
```

`tools/wdadrive.py` drives the UI over WebDriverAgent, pulls that log after each profile, and
prints the union plus the names of everything still uncovered.

**What the number does and does not mean.** `FLAGREAD` proves a branch was *evaluated*. It does
not prove the branch did the right thing. It is a map of untested surface, not a correctness
result. The actual fault signals are `FLAGRISK` lines (a guard caught a missing selector or a
dead KVC key) and crashes. Treat a rising coverage number as "we are now looking at more of the
code", not "more of the code is correct".

## Why one `all=on` run is not enough

`all=on` forces every bool YES, and that is what unblocks **nested** gates — `24hrFormat` is only
read inside `addEndTime()`, which early-returns unless `videoEndTime` is on, so with defaults it
can never be reached no matter how long you tap.

But `all=on` also switches on every flag whose job is to *remove UI*: `hideShorts` hides Shorts,
`removeShareMenu` removes the share row, `removeSubscriptions` deletes the tab. A maximal run
makes the very surfaces you need unreachable — coverage drops *because* you maximised it.

So we run profiles and take the union. `off=` beats the `all=on` baseline in the control file,
which is the lever that makes this work:

| profile | control file | purpose |
|---|---|---|
| `nav`   | `all=on` + `off=<NAV_BLOCKERS>` | every branch on, except the ~17 flags that delete navigation UI |
| `allon` | `all=on` | the on-branch of those removers, at launch |
| `off`   | `all=off` | baseline; the `%orig` paths |

## Journeys

Each journey targets one cluster that launch-only never evaluates.

| journey | targets |
|---|---|
| `feed` | feed, tab bar, feed header, launch cold-config |
| `watch` | the player cluster — the largest at 36 flags |
| `fullscreen` | `portraitFullscreen`, `allowedFullScreenOrientations`, the `noFeedRotation` interaction |
| `pip` | `pipReentryFix` / `ytlPipRearm`, background playback |
| `menu` | the 7 `remove*Menu` flags |
| `share` | `noShareChunk` (the `si=` strip, incl. the `_UIConcretePasteboard` setters) |
| `shorts` | 9 Shorts flags incl. `shortsProgress`, `hideShortsActionBar` |
| `settings` | `noHints`, and the five `Settings.x` KVC sites that were unguarded |

## Two traps worth not re-deriving

**Enter the watch page by URL, not by tapping the feed.** The feed's top slot is frequently a
Shorts shelf (`short-item-index-N`) whose cells carry no duration label, so a heuristic
"find a video cell and tap it" opens a *Short* — and the whole 36-flag player cluster silently
stays uncovered while the journey reports success. `libreyt://watch?v=<id>`, delivered with
`devicectl ... --payload-url`, drives the universal-link path straight to the player every time.

**Journeys must be isolated.** `watch` leaves a player up and `pip` leaves a miniplayer, and the
pivot bar is then absent from the accessibility tree — so every Shorts/You/Subscriptions tap that
follows fails and its cluster goes uncovered. That reads exactly like "those hooks are dead" when
the harness is really just tapping at a screen that moved. `reset()` terminates and relaunches
before each journey; it also gives each one its own `RUNSTART`, which makes the log readable.

## Running it

Prerequisites: WebDriverAgent running (`ios tunnel start`, `ios runwda`, `iproxy 8100:8100 -u <udid>`),
device **unlocked and awake**, and a `FLAG_DEBUG` build installed via Sideloadly (so it lands on the
same container and keeps the login).

```bash
make clean package DEBUG=0 FINALPACKAGE=1 FLAG_DEBUG=1     # or tools/flagdbg-ipa.sh for a full IPA
export SP=/tmp/wdasweep
python3 tools/wdadrive.py explore                           # dump the live a11y tree
ALLFLAGS=all.flags OUT=$SP python3 tools/wdadrive.py run    # full plan
ONLY=nav:pip OUT=$SP  python3 tools/wdadrive.py run         # one profile:journey
```

`all.flags` is the 97-key list; regenerate it by extracting every `ytlBool`/`ytlInt` key from the
hook sources. Artifacts land in `$OUT`: `report_<profile>.log`, `raw_<profile>.log`, `union.flags`,
screenshots and `tree_*.txt`.

## Known-good signals

- `FLAGRISK ... flag=videoEndTime sel=playbackRate cls=YTSingleVideoController` is **expected** on
  21.36.6. `playbackRate` was removed; the guard catches it and falls back to 1x. It is the guard
  working, not a regression. Removing the dead probe entirely is a cleanup, not a fix.
- `RUNSTART v<version>` must match the build you think you installed. It will not if you rebuilt
  over the same IPA filename and did not reinstall — a mistake that has cost a full debugging cycle
  more than once.

## What still needs a human

- **Screen lock** as a PiP trigger. WDA can lock, but its unlock is a swipe and this device has a
  passcode, so an automated lock can strand the run. Lock the device by hand with PiP active.
- Anything behind sign-in-gated or age-gated content (`noContentWarning`).
- Visual regressions. Screenshots are captured per journey, but nothing diffs them; a pink tint or
  an oversized thumbnail is still an eyeball check.

## Case study: what the PiP journey actually established

Worth reading before trusting any automated PiP result.

`pipReentryFix` had been read **zero** times in every prior sweep — the re-entry fix had never
once been exercised, because a launch-only sweep never backgrounds the app. The `pip` journey
drives `wda/deactivateApp`, which does fire `ytlPipRearm`. So far so good.

But comparing the automated cycles against the user's own manual use in the same log:

|  | manual (real home swipe) | automated (`deactivateApp`) |
|---|---|---|
| `APP → background` state | `possible=1 active=1` | `possible=0 active=0` |
| `willStart` / `didStart` | yes, every time | **never**, ~12 cycles |
| `PGPegasus -1003` | none | 20 |

**WDA's `deactivateApp` is not equivalent to a home swipe for PiP.** Auto-PiP needs the real
backgrounding path, which is what makes YouTube call `activatePiPController` on the way out. Under
automation PiP never arms, so it can never start — and every "failure" the automated run reports
is an artifact of the harness, not a defect. An automated PiP run can confirm that `ytlPipRearm`
*fires* and what the guard *saw*; it cannot confirm that PiP works, and `didStart=0` from a driven
run is not evidence of a bug.

The manual log, by contrast, shows the fix doing exactly its job:

```
willStop → restoreUI → didStop → deactivate      (YouTube tears PiP down on return)
reentry-fix: re-arm #3 (possible=0)
reentry-fix: after re-arm #3 possible=1          (we re-arm it)
APP → background (possible=1 active=0) → willStart → didStart   (next PiP starts)
```

One real, attributable mechanism did come out of the A/B (`pipbg` vs `pipnobg`, differing in
`backgroundPlayback` alone): **`activatePiPController` only takes effect when `backgroundPlayback`
is on.** With it on, the re-arm flips `possible` 0→1 every time (3/3). With it off, `possible`
stays 0 through all four attempts (0/24) — the layer never readies and re-arming is insufficient,
which is precisely the case the comment above `ytlPipRearm` predicts and names the next step for.
