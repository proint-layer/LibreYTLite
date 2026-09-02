# LibreYTLite

A clean, open-source fork of [YTLite](https://github.com/Dayanch96/YTLite), branched from the last MIT-licensed release before the project went closed-source. Rebuilt from source without DRM, for sideloading.

## Getting the IPA

Fork this repo and trigger the **Build YTLite IPA** workflow from the Actions tab. Paste a decrypted YouTube IPA URL and select which bundled tweaks to include. The patched IPA is uploaded as an artifact.

## Compatibility

Verified against **YouTube 21.25.5** and **21.31.3**. LibreYTLite tracks a rolling window of recent major YouTube versions: when a new major version lands, the hooks are audited against it and any renamed classes/selectors are dual-hooked so earlier versions keep working (e.g. `MLPIPController` → `MLPIPControllerImpl` in 21.31.x). Versions outside the tested window may still work but aren't verified — prefer a YouTube IPA from the tested set.

## Features

- Ad blocking (pre-roll, banner, and overlay ads)
- Background playback
- Return YouTube Dislikes
- YTABConfig (A/B flag overrides)
- DontEatMyContent (safe area fix)
- Shorts hiding and controls
- Speed controls (up to 5×)
- Tab bar customization
- iSponsorBlock (crowd-sourced sponsor-segment skipping)
- Watch queue — a client-side play queue with a reorderable viewer (long-press a video → *Add to queue*)
- Community-post image viewer — tap to zoom, page multi-image galleries, save to Photos
- Remove share identifier — strips YouTube's `si=` tracking parameter from links you share
- Open YouTube links in the app — route links from Safari (or any app) into LibreYTLite instead of stock YouTube ([setup below](#open-youtube-links-in-the-app))
- Native iOS share sheet
- And everything else from the original YTLite settings

> **Want 4K / high-bitrate video or the in-player quality switcher?** Those extras (YTUHD + YouQuality, via YTVideoOverlay) live on the [`full`](../../tree/full) branch. `main` is the leaner default without them.

## Open YouTube links in the app

By default, tapping a YouTube link — or "Open in YouTube" — sends you to the **stock** app, because a sideloaded build can't claim YouTube's universal links. LibreYTLite registers its own `libreyt://` URL scheme so you can route links here instead. Pick either method (or both).

**Prerequisite:** build/install LibreYTLite **4.6.0 or later** (the scheme is registered at build time).

### A. From the share sheet — no extra app

Add a one-action Shortcut that shows up in Safari's share sheet:

1. Open the **Shortcuts** app → **＋** (new shortcut) → name it **Open in LibreYTLite**.
2. Tap ⓘ → turn on **Show in Share Sheet**; set **Accepted Types** to **URLs** (add *Safari web pages* if you like).
3. Add a **Replace Text** action — input **Shortcut Input**, **Find** `^https?://` with **Regular Expression** ON, **Replace** with `libreyt://`.
4. Add an **Open URLs** action fed by the Replace Text result.

Now, on any YouTube page in Safari: **Share → Open in LibreYTLite**.

### B. Automatically when you tap a link — RedirectWeb

Use the App Store extension **[RedirectWeb](https://apps.apple.com/us/app/redirect-web-browser-ext/id1571283503)**. Because it's signed by Apple it works reliably — unlike a bundled Safari extension, which breaks when a sideloader re-signs it.

1. Install **RedirectWeb** from the App Store.
2. **Settings → Safari → Extensions → RedirectWeb** → enable it, and allow it on `youtube.com`.
3. In RedirectWeb, add two redirect rules (regex with a capture group):
   - `https?://(?:www\.|m\.)?youtube\.com/watch\?v=([\w-]+)` → `libreyt://watch?v=$1`
   - `https?://youtu\.be/([\w-]+)` → `libreyt://youtu.be/$1`

Tapping a YouTube link in Safari now routes it into LibreYTLite. Safari may ask you to confirm the app-open the first time — that's an iOS security prompt for launching an app from an extension, not a bug.

## Credits

- [Dayanch96](https://github.com/Dayanch96) — original YTLite
- [PoomSmart](https://github.com/PoomSmart) — YouTubeHeader, YouGroupSettings, YTVideoOverlay, Return-YouTube-Dislikes, YTABConfig, YouQuality
- [arichornlover](https://github.com/arichornlover/uYouEnhanced) — uYouEnhanced (EML-based feed filtering approach)
- [Tonwalter888](https://github.com/Tonwalter888) — YTUHD
- [therealFoxster](https://github.com/therealFoxster) — DontEatMyContent
- [Galactic-Dev](https://github.com/Galactic-Dev) — iSponsorBlock
- [asdfzxcvbn](https://github.com/asdfzxcvbn) — cyan (pyzule-rw), the injection tool
- [Dan Pashin](https://github.com/danpashin) — special thanks

## AI Attribution

All code in this fork from v3.0 onward was written entirely by Claude (Anthropic). No code was manually authored by the maintainer.
