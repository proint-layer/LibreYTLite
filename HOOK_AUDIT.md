# Hook audit — dead hooks on YouTube 21.x

A method-level audit of every `%hook` in the tweak, cross-referenced against the
Objective-C class/method dumps of **YouTube 21.25.5** (target) and **21.16.2**
(older reference), triggered after discovering that
`-[YTPlayerViewController loadWithPlayerTransition:playbackConfig:]` — the hook
the watch-queue engagement hung off — **does not exist on that class**, so it
never fired.

A **dead hook** is a `%hook Class` + method where the selector isn't present on
that class in the binary. Logos compiles it fine, Substrate installs nothing,
and it silently never runs — no crash, no log, no signal. Most of the ones below
are **inherited from upstream YTLite**, not introduced by this fork, and most are
dead in *both* 21.16.2 and 21.25.5 (i.e. they've been dead across the whole 21.x
line, not "removed recently" — a claim the audit was careful not to assume).

## Method & its blind spots

A throwaway script parsed each `.x`, extracted every non-`%new` hook method, and
checked the selector against `-[Class …]`/`+[Class …]` lines in the dump (rebuild
the dump with `ipsw macho info --objc Payload/YouTube.app/YouTube`). Known false
positives it flags but that are **valid** (verified, ignore):

- **UIKit/Foundation/private classes not in the app dump** — `_UIConcretePasteboard`
  (confirmed on-device to be what `generalPasteboard` returns), `NSBundle`,
  `NSFileManager`, `NSParagraphStyle`.
- **Inherited methods** — e.g. `titleLabel` on `YTQTMButton`
  (`YTQTMButton → YTLightweightQTMButton → UIButton`, so it's a UIButton property).
- **System lifecycle** — `viewDidLoad`, `layoutSubviews`, `setImage:`, etc.

Everything this fork *added* (pasteboard `si=` strip, queue viewer, community-post
gallery, native share) audited clean.

> Caveat: "dead" means **the hook can't fire** (strong, static). The repoints
> below target the verified-present current selector, but firing + behavior are
> **not yet on-device-confirmed** — same rigor gap that produced the original
> `loadWithPlayerTransition` mistake. Treat "fixed" as "repointed, pending test."

## A. Repointed to the live selector (feature should be revived)

| # | Was (dead) | Now | Backs | Confidence |
|---|---|---|---|---|
| 1 | `YTPlayerViewController loadWithPlayerTransition:playbackConfig:` | `playbackController:didActivateNewPlaybackWithContentVideo:` | queue engagement + auto-quality/fullscreen/speed/captions | high (present); **firing pending device test** |
| 2 | `YTDataUtils +spamSignalsDictionary` / `+…WithoutIDFA` | `YTAdShieldUtils` (same selectors, `+`) | ad spam-signal stripping (`noAds`) | high |
| 3 | `YTColdConfig videoZoomFreeZoomEnabledGlobalConfig` | `videoZoomFreeZoomEnabled` | Disable Free Zoom (`noFreeZoom`) | high |

## B. Removed — redundant dead lines (a valid sibling already does the job; zero runtime change)

| Removed | Feature still works via |
|---|---|
| `YTReelPlayerViewController shouldEnablePlayerBar` | `shouldAlwaysEnablePlayerBar` (same block) |
| `YTColdConfig mobileShortsTabInlined` + `YTHotConfig enablePlayerBarForVerticalVideoWhenControlsHiddenInFullscreen` | `iosEnableVideoPlayerScrubber` + `shouldAlwaysEnablePlayerBar` (`shortsProgress`) |
| `YTMainAppVideoPlayerOverlayViewController setPaidContentWithPlayerData:` | `playerOverlayProvider:didInsertPlayerOverlay:` identity check (same block) |
| `SSOKeychainCore +accessGroup/+sharedAccessGroup` | `SSOKeychainHelper` (valid, same file) |
| `YTPlayerViewController singleVideo:currentVideoTimeDidChange:` | `potentiallyMutatedSingleVideo:…` twin already hooked in the same block (drives end-time + auto-skip) — the build's redefinition error caught this |
| `OGLPhenotypeFlagServiceImpl bundleId` | the `NSBundle` bundle-id hooks |
| `YTPlaybackConfig setEnablePlayerAdUIRendering:` | ads already stripped at `YTIPlayerResponse` |

## C. Dead, no 21.x equivalent found — feature currently inactive (flagged in-code, toggle is a no-op)

These have no live replacement I could verify; left in place with a `// DEAD (21.x)`
marker so they're no longer silent, and tracked here for future rename-hunting. Their
Settings toggles currently do nothing.

| Hook | Toggle | Note |
|---|---|---|
| `YTColdConfig enableChipsInTheCommentsHeaderIos` | `hideSortComments` | no clear rename (distinct from the valid `enableHideChipsInTheCommentsHeaderOnScrollIos`) |
| `YTColdConfig shouldUseAppThemeSetting` | `useSystemTheme` | no clear rename found |
| `YTColdConfig isLandscapeEngagementPanelSwipeRightToDismissEnabled` | (dismiss panel by swiping) | no match in 21.x |
| `YTColdConfig iosUseSystemVolumeControlInFullscreen` | `stockVolumeHUD` | no match in 21.x |
| `YTReelWatchPlaybackOverlayView set{ReelLike,ReelDislike,ViewComment,Remix,Share,NativePivot,PivotButtonElementRenderer}Button:` (×7) | `hideShorts{Like,Dislike,Comments,Remix,Share,Avatars}` | class exists but has **no** `set*Button:` — Shorts overlay buttons moved to a different (likely EML) mechanism; needs RE |

## Follow-ups

- On-device confirm A#1–4 actually fire (the whole point of the audit was that "present" ≠ "fires").
- Rename-hunt or retire the category-C toggles (they mislead users as-is).
- Revive `hideShorts*` if worth it: `YTReelWatchPlaybackOverlayView` now drives its overlay via
  element-renderer setters (`setActionBarElementRenderer:`, `setInfoPanelElementRenderer:`,
  `setMetapanelElementRenderer:`) rather than per-button setters — a rewrite against those is the path.

_Independently re-verified 2026-07-29 by an adversarial subagent scan (110 `%hook` blocks / 171
methods): all A/B repoint+removal claims confirmed present/absent as stated, build passes, and the
only remaining dead hooks are exactly the category-C set above (now marked in-code)._
