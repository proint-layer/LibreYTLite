# AGENTS.md — LibreYTLite

This file orients human and AI contributors working in this repo. Read it before making changes.

## 1. What this project is

LibreYTLite is a clean, **from-source** open fork of [YTLite](https://github.com/Dayanch96/YTLite), an iOS tweak that patches the stock YouTube app to add ad-blocking, background playback, quality/speed unlocks, UI cleanup, and download helpers. It is written in Objective-C using **Theos + Logos** and is injected into a decrypted YouTube IPA for sideloading (rootless-capable).

**Philosophy — from source, no DRM.** The fork is branched from the last MIT-licensed release of upstream YTLite (`Copyright (c) 2023 dayanch96`, see `LICENSE`) before that project went closed-source. The closed 5.x line ships a separately-injected DRM binary and obfuscates its identifier strings with XOR encoding. This fork deliberately contains **only buildable source** — no pre-built blobs, no DRM, no obfuscation — so the entire tweak can be audited and compiled by anyone. When adding code, never introduce a pre-compiled binary dependency or anything that can't be built from source in CI.

Note the internal name is still `YTLite`: the tweak target, the `com.dvntm.ytlite` package/defaults suite, and the `YTLite.bundle` resource bundle all keep the upstream names for drop-in compatibility. "LibreYTLite" is the fork's public identity only.

## 2. Repo layout

```
YTLite.x            Main tweak — all runtime/player/feed/ad hooks (~2900 lines)
Settings.x          In-app settings UI (hooks YTSettingsSectionItemManager etc.)
Sideloading.x       Keychain access-group + bundle-ID patching for sideloaded IPAs
YTNativeShare.x     Native iOS share sheet integration
YTLite.h            Shared header: LOC/ytlBool macros + private class/method decls
YouTubeHeaders.h    Imports of PoomSmart YouTubeHeader classes used across the tweak
YTLite.plist        Logos filter — loads only into com.google.ios.youtube
Makefile            Theos build config
control             dpkg control (package com.dvntm.ytlite)
Utils/
  YTLUserDefaults.{h,m}   Settings store (NSUserDefaults suite) + registerDefaults
  NSBundle+YTLite.{h,m}   ytl_defaultBundle lookup backing LOC()
  Reachability.{h,m}      Network reachability helper (vendored — leave as-is)
layout/Library/Application Support/YTLite.bundle/
                    Localization (.lproj/Localizable.strings) + assets, staged into the package
tweaks/             Optional features as git submodules (see .gitmodules)
.github/workflows/build.yml   CI: build tweaks + inject into IPA
```

`YTClean/`, `HANDOFF.md`, `*.ipa`, `*.deb`, and `.theos/` are gitignored local artifacts (not in the repo). If you have a local `HANDOFF.md`, ignore it — it is a stale pre-fork plan (it predates the rename of `Tweak.x` → `YTLite.x`, the switch from azule → cyan, and iSponsorBlock replacing a hand-written SponsorBlock).

## 3. Architecture

**Logos hooks.** Behavior is added by `%hook <Class> … %end` blocks with `%orig` to call through, `%new` for injected methods/properties, and a single `%ctor` (bottom of `YTLite.x`) for load-time setup. Private YouTube classes/selectors not covered by the YouTubeHeader project are forward-declared in `YTLite.h` / `YouTubeHeaders.h`. `Sideloading.x` wraps its hooks in a `%group` that is `%init`-ed only when running sideloaded.

**Settings pattern — `ytlBool()`.** All feature flags live in `YTLUserDefaults` (suite `com.dvntm.ytlite`). `YTLite.h` defines the accessors used everywhere:
- `ytlBool(@"key")` / `ytlInt(@"key")` — read
- `ytlSetBool(v,@"key")` / `ytlSetInt(v,@"key")` — write

Every hook guards its effect on a flag, e.g. `if (ytlBool(@"noAds")) …`. Defaults are declared once in `-[YTLUserDefaults registerDefaults]`.

The settings screen is built in `Settings.x` by `-[YTSettingsSectionItemManager updateYTLiteSectionWithEntry:]`. Simple toggle rows use the `%new` helper `-[YTSettingsSectionItemManager switchWithTitle:key:]`, which binds a switch to a defaults key. Multi-choice rows (rate, quality, startup tab, language) are **not** switches — they use `detailTextBlock`/`selectBlock` and push a `YTSettingsPickerViewController`. Some whole sections are gated behind `ytlBool(@"advancedMode")`.

**Localization — `LOC()`.** `LOC(@"Key")` resolves against `NSBundle.ytl_defaultBundle` (the injected `YTLite.bundle`). Keys are self-documenting English identifiers; strings live in `layout/Library/Application Support/YTLite.bundle/<lang>.lproj/Localizable.strings`. To list all keys in use: `grep -o 'LOC(@"[^"]*")' *.x`.

**Optional tweaks as submodules.** Bundled features that are their own upstream projects are git submodules under `tweaks/` (see `.gitmodules`): PoomSmart's `YouGroupSettings`, `YTVideoOverlay`, `Return-YouTube-Dislikes`, `YTABConfig`, `YouQuality`; `DontEatMyContent` (therealFoxster); `YTUHD` (Tonwalter888); `iSponsorBlock` (Galactic-Dev); and `Alderis` (hbang — the color-picker framework iSponsorBlock depends on). They are built independently and injected alongside the main tweak — the core `YTLite` tweak does not link against them.

## 4. Build & inject workflow

**Prerequisites (local):** a working [Theos](https://theos.dev) install (`$THEOS` set), the **iOS 16.5 SDK** in `$THEOS/sdks`, and these header sources where the build expects them:
- PoomSmart's YouTubeHeader cloned to `../YouTubeHeader` (relative to repo root)
- protobuf `v3.25.8` cloned to `../protobuf`
- For optional tweaks: PoomSmart's `PSHeader` in `$THEOS/include/PSHeader` (and YouTubeHeader copied into `$THEOS/include/`)

**Build the core tweak:**
```bash
git submodule update --init --recursive     # only if building optional tweaks
make clean package DEBUG=0 FINALPACKAGE=1    # → packages/com.dvntm.ytlite_*.deb
```
Makefile facts: `TWEAK_NAME = YTLite`, `ARCHS = arm64`, target `iphone:clang:latest:13.0`, `-fobjc-arc`, `-DTWEAK_VERSION` from `PACKAGE_VERSION`, and `YTLite_FILES = $(wildcard *.x Utils/*.m)` (new `.x` files at the root and `.m` files in `Utils/` are picked up automatically). Pass `ROOTLESS=1` for the rootless package scheme.

**Inject into a YouTube IPA with cyan** (asdfzxcvbn's pyzule-rw). Each deb/dylib/framework is a separate `-f` argument:
```bash
cyan --overwrite -i youtube.ipa -o LibreYTLite.ipa \
  -f packages/com.dvntm.ytlite_*.deb \
     tweaks/YTUHD/packages/*.deb  ...other tweak debs... \
     tweaks/iSponsorBlock/packages/*.deb \
     tweaks/Alderis/libcolorpicker.dylib \
     tweaks/Alderis/.theos/obj/install_Alderis.xcarchive/Products/Library/Frameworks/Alderis.framework
```
iSponsorBlock is special: build `tweaks/Alderis` first, copy its `libcolorpicker.dylib` into `$THEOS/lib` **before** building `tweaks/iSponsorBlock`, and inject **both** `libcolorpicker.dylib` and `Alderis.framework` alongside the iSponsorBlock deb or it crashes on launch. (Alderis' `lcpshim`/libcolorpicker needs the `Preferences` private framework, which only exists in Theos' 16.5 SDK, not the Xcode SDK.)

**GitHub Actions path (`.github/workflows/build.yml`)** — the supported/reproducible build. `workflow_dispatch` inputs: `ipa_url` (decrypted YouTube IPA), `display_name`, `bundle_id`, and `enable_*` toggles per optional tweak. Two jobs:
1. **build** (macOS): installs deps, restores/pins Theos at `9bc73406…`, fetches the 16.5 SDK, clones YouTubeHeader/protobuf, `make package` for `YTLite`, then conditionally builds each enabled submodule tweak (plus its deps) and uploads all `*.deb`/`*.dylib`/`*.framework` as an artifact.
2. **package** (macOS): downloads the artifacts + the user's IPA, `pipx install`s cyan, and injects everything into the final IPA. Mirror this job structure when adding a new optional tweak.

## 5. Adding a hook or a setting

Adding a **hook**: forward-declare any unknown class/selector in `YTLite.h` (or import it via `YouTubeHeaders.h` if PoomSmart's headers already cover it), add a `%hook … %end` block in `YTLite.x` under the relevant section banner, and gate its effect behind `ytlBool(@"yourKey")` so it can be toggled.

Adding a **setting** end-to-end:
1. Register its default in `-[YTLUserDefaults registerDefaults]` (`Utils/YTLUserDefaults.m`).
2. Add a toggle row in the right section of `Settings.x`, e.g. `[self switchWithTitle:@"YourTitleKey" key:@"yourKey"]` (or a `detailTextBlock`/`selectBlock` row for a multi-choice setting).
3. Add `YourTitleKey` (and its `…Desc` description key, if used) to `layout/Library/Application Support/YTLite.bundle/en.lproj/Localizable.strings`.
4. Read it in the hook with `ytlBool(@"yourKey")`.

**Every commit must build.** Never commit or push code that doesn't compile. Before committing, run `make clean package DEBUG=0 FINALPACKAGE=1` (see §4) and confirm it finishes with **zero errors and zero warnings** — `-Werror` is on (see §6), so a warning *is* a failed build. Every commit on `main` must leave the tree in a buildable state: if a change spans multiple commits, keep each one compilable, not just the last. Release builds must also be clean of diagnostics — no `[YTLITE]` strings in the shipped dylib (build without `-DYTL_POST_DEBUG`).

**Comment the gnarly bits — explain the WHY and the traps, not the what.** This codebase deliberately over-documents its hard-won parts, and contributions (human or LLM) are expected to keep that up. The house style is set by the code itself and stated in the git history — see commits `a147659` ("HolyC-style comments on the gnarly bits") and `f3441e9` ("human/LLM-friendly comments"): a blunt, first-person voice that captures the *reason* a hook exists and the *trap* that bites you, not a restatement of what the line literally does. When you add or change a non-obvious hook, leave a war-story comment so the next contributor doesn't have to re-derive it from a device session — the race/ordering quirk, the version-specific class name, the `%orig` you must (or must not) call, the thing that looks removable but isn't. Group new hooks under the right `// ===` feature section banner in `YTLite.x`, and if you add or move a section, update the section-map header at the top of the file. Self-evident code needs no comment; a subtle gesture-arbitration, a class-cluster gotcha, or an EML byte-scan earns a paragraph.

## 6. Hard-won gotchas

- **EML / ASDK identifiers drift between YouTube versions — match broadly.** Feed cells, ads, and buttons are EML `elementRenderer`s (YouTube 19+); identify them by substring-scanning `-[… description]` against **arrays of candidate fragments** (see `isAdElementRenderer` and the `adStrings` / shorts arrays), not exact equality. Ads also expose `compatibilityOptions.hasAdLoggingData` — check that too. Never hardcode a single full identifier; it will break on the next app update.
- **Gesture recognizers on feed cells must be coordinated and scroll-gated, and a long-press must out-arbitrate YouTube's own cell-tap.** Injected long-presses on an `_ASDisplayView` (community posts) compete with YouTube's tap that opens the post detail page. All injected recognizers share the `YTLGestureCoordinator` delegate: it returns `YES` from `shouldRecognizeSimultaneouslyWithGestureRecognizer:` (so our gesture never blocks a native one) **and** `YES` from `shouldBeRequiredToFailByGestureRecognizer:` scoped to *tap-vs-long-press only* — that makes YouTube's cell-tap wait for our long-press to fail, so when the long-press wins (menu opens) the tap never fires and the app doesn't navigate on finger-lift; a quick tap fails the long-press instantly, so normal tap-to-open-post still works. `ytlConfigureLongPress()` also sets `cancelsTouchesInView = YES`, `delaysTouchesBegan/Ended = NO`, `minimumPressDuration = 0.4`; `postManager:` additionally disables ancestor tap recognizers for 0.6s (`ytlSuppressAncestorTaps()`) as belt-and-suspenders. Always bail out of the handler when an enclosing scroll view `isDragging`/`isDecelerating` (`ytlEnclosingScrollActive()`) so a scroll-stopping touch isn't misread as an interaction. **Lesson: don't try to hijack YouTube's cell-tap to open the viewer — use a long-press menu (as paid YTLite 5.x does); the failure-requirement is what reliably suppresses the stray navigation.** Build with `ADDITIONAL_CFLAGS="-DYTL_POST_DEBUG"` to get `ytlDumpRecognizers()` output (the full recognizer tree at long-press time) when diagnosing gesture issues.
- **Google image CDN: rewrite to `=s0` for full-res.** ggpht / googleusercontent URLs carry a size/crop token after the first `=` (e.g. `=s800-c-fcrop64=…`). Replace the whole token with `=s0` (original, uncropped) via `ytSizedURLString()` / `ytMaxResURLString()`; use `=s2048` for a fast progressive preview. Leave non-Google URLs (`i.ytimg.com`, `/vi/` video thumbnails) untouched.
- **Photos save needs read-write authorization.** This app's Info.plist has no `NSPhotoLibraryAddUsageDescription`, so the shared save path (`ytlEnsurePhotosAuth`) requests `PHAccessLevelReadWrite` (with the pre-iOS-14 fallback) before `performChanges:`, and saves the original downloaded **bytes** via `addResourceWithType:` — not `creationRequestForAssetFromImage:` (which re-encodes and fails with `PHPhotosErrorInvalidResource` 3302) and not `UIImageWriteToSavedPhotosAlbum` (needs the missing add-only key).
- **Community-post images load lazily — capture URLs at feed time.** A multi-image post's attachment is an EML `elementRenderer` (not a plain image array), and its images render lazily so they aren't reachable from the view tree when tapped. `ytlScanAndCacheImages()` (called from the `YTIElementRenderer` `elementData` hook, cheaply gated on the `fcrop64` byte marker) parses the raw EML bytes and caches the ordered, `=s0`-normalized URL group in `gYTLImageGroups`; the tap handler looks the tapped URL up to page the whole set in `YTLImageViewer`.
- **The "queue" is a from-scratch reimplementation — YouTube's native queue is server-locked.** "Add to queue" / "Play next in queue" is Premium-gated *server-side*: for a non-Premium account the server delivers those buttons with an upsell command inside a generic `YTICommand` (no client-side queue handler ever fires), so it can't be unlocked by flipping flags or hooking a handler. Instead `enableQueue` gives us our own queue: a long-press on a feed video cell (`YTVideoWithContextNode`, attached in `setKeepalive_node:`) reads the 11-char videoID straight from the cell's thumbnail URL (`i.ytimg.com/vi/<ID>/…`, via `ytlVideoIDFromThumbnailURL`), stores it in the in-memory `YTLQueueManager`, and `%hook YTPlayerViewController playbackControllerDidFinishPlayback:` auto-plays the next one. Playback (`ytlPlayVideoID`) fires a `YTCommandResponderEvent` built from `[YTICommand watchNavigationEndpointWithVideoID:]` handed the live player as first responder — this plays in-place and, crucially, **works while backgrounded** (the old `vnd.youtube://<ID>` deep-link is blocked when backgrounded and now survives only as a last-ditch fallback). A long-press "View queue (N)" opens `YTLQueueViewController`, a bottom-sheet table (tap-to-play, swipe-remove, drag-reorder, clear) that stands in for the native "Up next" panel. The cells' own native long-press menu is AsyncDisplayKit-internal (`_ASCollectionViewCell`, fires only from a live gesture) so it can't be re-triggered from our sheet — its actions stay on the cell's ⋯ button.
- **Stripping the share `si=` identifier means hooking two divergent paths — and `UIPasteboard` is a class cluster.** The `noShareChunk` feature (SHARE LINK PRIVACY section) removes YouTube's per-share `si=` tracking token from links you share, without replacing the share sheet (unlike `nativeShare`). "Copy link" is ELM-driven and lands the URL on the clipboard as a plain **string**, so an NSURL-typed sharer hook never sees it. Critically, `[UIPasteboard generalPasteboard]` returns a private **`_UIConcretePasteboard`** whose setters override the public class's — so `%hook UIPasteboard` instance hooks **never fire** for the real pasteboard. Hook **`_UIConcretePasteboard`** instead (confirmed via a `+generalPasteboard` class probe). We scrub `si` there across the setter surface (`setString:` is the one copy-link uses) via `ytlStringStripSi`, a regex gated to youtube links carrying an `si` param. Messages/Mail/system-sheet still use the legacy `YT*Sharer` composers, whose `shareObjectWithID:…:URL:…` NSURL arg we clean with `NSURLComponents`. Lesson for any clipboard interception: hook the concrete class, not `UIPasteboard`.
- **You cannot wrap a `%hook`/`%new` block in a C `#if`.** Logos preprocesses `%`-directives *before* the C preprocessor runs, so it emits a trampoline declaration that `#if defined(YTL_POST_DEBUG) … %hook … %end … #endif` then guts in release builds → `_logos_meta_method$… has internal linkage but is not defined` (`-Werror,-Wundefined-internal`). Put the `#if` *inside* the method body, or leave the hook unconditional and no-op its effect — never gate the `%hook` itself.
- **`YTL_POST_DEBUG` compile flag** enables `[YTLITE]`-prefixed diagnostics: `YTLDBG(...)` maps to `os_log(… "%{public}@" …)` (plain `NSLog` redacts dynamic values as `<private>`, and `%{public}@` is rejected by `-Werror` outside `os_log`). Off in release; build with `ADDITIONAL_CFLAGS="-DYTL_POST_DEBUG"` to trace feed/post capture, then read on device with `log stream --predicate 'eventMessage CONTAINS "YTLITE"'`.
- **`-Werror` is on.** Warnings fail the build: no deprecated-API calls, no unused code/variables/parameters. Clean up dead branches and unused locals before committing.

## 7. Reverse-engineering the current YouTube binary

Identifiers change across YouTube releases, so re-derive them from the actual binary rather than trusting old constants:
- `ipsw macho info --objc <YouTube binary>` — dumps the Objective-C class/protocol/method layout (the primary way to confirm a class name, selector, or property before hooking it). `otool` (`-ov`, `-L`, `-s __TEXT __cstring`) covers ObjC sections, linked libraries, and embedded C strings.
- Cross-check against PoomSmart's YouTubeHeader, which tracks many of these across versions.
- Do **not** try to lift identifiers from the closed YTLite 5.x binary: it XOR-obfuscates its strings, so they won't appear in a plain dump. Rebuild them from the clean, live YouTube binary instead — consistent with this fork's from-source, no-obfuscation stance.
