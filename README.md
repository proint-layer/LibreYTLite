# LibreYTLite

A clean, open-source fork of [YTLite](https://github.com/Dayanch96/YTLite), branched from the last MIT-licensed release before the project went closed-source. Rebuilt from source without DRM, for sideloading.

## Getting the IPA

Fork this repo and trigger the **Build YTLite IPA** workflow from the Actions tab. Paste a decrypted YouTube IPA URL and select which bundled tweaks to include. The patched IPA is uploaded as an artifact.

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
- Native iOS share sheet
- And everything else from the original YTLite settings

> **Want 4K / high-bitrate video or the in-player quality switcher?** Those extras (YTUHD + YouQuality, via YTVideoOverlay) live on the [`full`](../../tree/full) branch. `main` is the leaner default without them.

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
