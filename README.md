# Continuity

A minimal native iOS music app whose one differentiating feature is **transitions so smooth
you don't notice a song changed** — a configurable, higher-quality take on Apple Music's
Automix: stem-separated, beatmatched, harmonically-mixed DJ blends.

This is a **personal portfolio prototype**. iOS 26+, SwiftUI + `AVAudioEngine`. Music is
sourced from YouTube (see [Caveats](#caveats)).

## What it does

**The transition engine** — a dual-deck `AVAudioEngine` graph where every track change is a blend:

- **Crossfade** — configurable duration (0–16 s) and curve (linear / equal-power / smooth)
- **Beatmatching** — tempo-matches the incoming track (`AVAudioUnitTimePitch`, ±8% cap,
  half/double-time aware) *and* beat-aligns its start so the incoming beat lands on an
  outgoing beat
- **Bass swap** — a low-shelf EQ fades the incoming low end in so basslines never stack
- **Harmonic mixing** — nudges the incoming track up to ±1 semitone into a Camelot-compatible
  key (DJ "key sync"); chained transitions track the effective key
- **Vocal-aware blends** — tracks are split into vocals + accompaniment stems on-device
  (HT-Demucs via ONNX Runtime; CoreML/Neural Engine on hardware), so the outgoing vocal can
  duck under the incoming instrumental: duck / instrumental-overlap / hard-swap modes
- **Loudness leveling** — integrated loudness is measured per track (BS.1770 K-weighting +
  gating) and per-deck makeup gain brings every track to −14 LUFS, so a quiet master never
  lurches into a loud one mid-blend
- **Gapless** — leading/trailing silence is detected per track and trimmed from transition
  timing (opt-out), so blends never run in dead air

**Analysis** — BPM + beat grid (spectral flux + autocorrelation with a perceptual tempo prior)
and musical key (tuning-corrected chroma → Krumhansl profiles → Camelot code), computed once
per track and cached; results are versioned so analyzer improvements re-analyze old libraries.

**The player** — the home screen is deliberately minimal: the app opens *playing* — a Now
Playing screen (blurred art, three controls) that resumes the previous session's song at its
saved position. Forward skips are budgeted, radio-style: 3, earned back by finishing tracks
and refunded when you step back (undoing a skip shouldn't leave it spent); previous-skips are
unlimited and walk a persistent play history. The full library (playlists, mini player,
detailed Now Playing with live transition settings and presets) lives in a sheet.

**Up Next** — a queue sheet shows what plays next: drag to reorder, swipe to remove, and
"Play Next" context menus throughout the library. A **Flow** toggle reorders the upcoming
tracks by key and tempo, like a DJ set — Camelot-wheel compatibility plus BPM proximity
(half/double-time pairs count as equal tempo), anchored on the current track. Pure logic in
`ContinuityCore/FlowOrdering`.

**Ingestion** — paste a YouTube video/playlist link or a Spotify playlist/album link.
Playlists paginate (~500-track cap); Spotify contributes the tracklist and each song's audio
is matched from YouTube. Tracks download (ranged, throttle-resistant), analyze, and
stem-separate in the background with bounded concurrency. Source-backed playlists **sync**
with their remote (opt-out auto-sync at launch, manual per-playlist and library-wide sync).

**Link redirection** — three ways links reach the app besides pasting: a `continuity://`
URL scheme (`continuity://import?url=…`); a share extension, so "share → Continuity" works
from Spotify or YouTube; and clipboard detection at launch — an importable link on the
clipboard triggers an import offer. Clipboard reads are privacy-conscious: pattern detection
(banner-free) runs *before* any read, each clipboard generation is inspected once, and every
path confirms with the user before importing.

## Project layout

```
project.yml                      XcodeGen spec — the project is generated, not committed
App/Continuity/                  thin app target: SwiftUI screens + wiring
  Views/                         minimal Now Playing, Library, Playlist, Up Next,
                                 Now Playing, Mini Player, Transition settings
  Library/                       link → import routing, sample data, orphaned-file cleanup
App/ShareExtension/              ContinuityShare target ("share → Continuity")
Packages/ContinuityCore/         pure-Swift, dependency-free core: crossfade curves,
                                 transition plan, beat/tempo math, BPM tracker, key
                                 detector, Camelot + flow ordering, loudness meter, silence
                                 trimming, and all YouTube/Spotify link/page parsing
Packages/ContinuityKit/Sources/
  Domain/                        SwiftData models (Playlist, Track), TransitionSettings,
                                 audio/stem caches
  Ingest/                        resolvers (YouTube/Spotify/oEmbed), downloader,
                                 preparation queue, analysis, stem separation (ONNX),
                                 playlist sync
  Playback/                      dual-deck engine (Player, Deck), Now Playing bridge,
                                 playback-state persistence
```

The layering is deliberate: modules depend only downward (Playback and Ingest are siblings
that meet through Domain), and everything fragile (page scraping) or mathematical (DSP,
transition logic) lives in `ContinuityCore` with no UIKit/AVFoundation dependency, pinned by
~114 unit tests. The upper layers do networking, audio I/O, and UI.

## Build & run

Requires Xcode 26+. The project file is generated by
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen          # once
xcodegen generate              # regenerate Continuity.xcodeproj from project.yml
open Continuity.xcodeproj      # then build/run on an iOS 26 simulator or device
```

## Test the core

The parsing and transition math compiles and tests without the app:

```sh
cd Packages/ContinuityCore && swift test
```

## Caveats

- **YouTube sourcing violates YouTube's ToS.** Acceptable only because this is a private
  prototype; it is not shippable as-is. The engine is source-agnostic — local files would
  drop in with no engine changes.
- **First stem separation downloads the model** (~165 MB, HT-Demucs fp16, cached after).
- **On the Simulator**, stem separation runs on CPU (~2–4 min/track); on hardware it uses
  the CoreML execution provider (Neural Engine). Sim CoreML is deliberately disabled — it's
  pathologically slow there.
- **Spotify playlists cap at ~50 tracks** (anonymous embed API limit; more needs OAuth).
- Playlist sync is **polling** (launch + manual) — push would need server infrastructure.

## Status

All planned milestones (M0–M5) are built: scaffold, YouTube/Spotify ingestion, dual-deck
crossfades, analysis + beatmatching, on-device stem separation with vocal-aware blends, and
config/persistence/stability polish. Remaining: validation on a physical device (Neural
Engine stem-separation timing, memory behavior under Jetsam).
