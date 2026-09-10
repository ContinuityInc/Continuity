# CLAUDE.md

Persistent memory for Claude sessions on Continuity. **Read `AGENTS.md` first** — it owns the
architecture, module layering, build commands, and code-level gotchas. This file holds what
AGENTS.md doesn't: the owner's preferences, hard-won debugging history, and operational
(CI/TestFlight) knowledge, so future sessions don't rediscover any of it.

## The owner & how they work

- Owner: sanylax (GitHub org `ContinuityInc`; accounts `sanylax0` — merges via web — and
  `sanylax2` — PR author, often gh-CLI rate-limited and can't approve its own PRs). Org ruleset:
  PRs required, 1 approving review to merge, **no force-push, no adding commits to an
  already-pushed branch** — finish a unit, push a *fresh* branch, open its PR.
- They asked the assistant to go by **Crossfade** in conversation.
- PR style: **one issue per PR** (stacked PRs when one issue needs several), **non-draft** when
  intended for merge, tight descriptions. They test on a real iPhone (iPhone18,1, iOS 26 beta)
  and report back with screenshots/console dumps — device verification is theirs; agents on
  Linux validate by review + ContinuityCore tests only.
- When they report a bug, they want root cause, not whack-a-mole: after repeated point-fixes
  failed on the OOM saga they explicitly asked for a full audit + RCA + testing plan. Prefer
  instrumentation-first debugging (see breadcrumbs below).

## Engineering history — why the code is the way it is

Do not regress these; each encodes a crash class that was painful to pin down.

### Jetsam/OOM saga (resolved)
Repeated "Terminated due to memory issue" kills on device, ~50s into playback. Root cause
chain, in fix order:
1. ORT prepacking off + release-session-on-drain, arena shrinkage
   (`memory.enable_memory_arena_shrinkage=cpu:0` per-run) + memory-warning abort.
2. `mem[...]` breadcrumbs (`MemoryFootprint.breadcrumb`, subsystem `com.continuity.app`,
   category `mem`) + a 200-tick playback heartbeat in `Player.tick()` — these pinned the death
   **inside ORTSession creation** with playback flat at ~3323 MB.
3. Final fix: `setGraphOptimizationLevel(.none)` on the HT-Demucs session — constant-folding
   the fp16 Cast nodes exploded session load past 3.3 GB. Verified: full songs play.
4. Structural guards (keep all of them): `StemSeparationBudget` headroom gate
   (`requiredStartMB=1400`, per-window floor `windowFloorMB=600`), 60s hold after playback
   start (`separationAllowedAt`), memory-warning abort, model stored in Application Support
   (Caches got evicted → silent 158 MB re-downloads at play time).

### Interruption SIGABRT (resolved)
Mid-song crashes (worst on first launch; one triggered exactly by a Siri announcement).
`AVAudioPlayerNode.play(at:)` with a **valid-but-stale** `lastRenderTime` hostTime after an
engine stop/restart raises an uncatchable AVFAudio exception. Fix in `Deck.play()` stem
branch: require the render clock to be *fresh* (host-time-valid, ≤ now, within 1s of now),
anchor at `mach_absolute_time()+0.03s`, else fall back to plain `play()` calls. Any new
`play(at:)` usage must follow the same freshness rule.

### Non-finite playback clock (resolved)
Transient crashes that clustered "when the phone is moving". The app uses **no** motion,
altimeter or location APIs, so no sensor was involved — movement is a proxy for **audio route
churn** (AirPods connecting/dropping, car stereos, a jostled cable) and network path changes.
Around a route or `AVAudioEngineConfigurationChange`, `AVAudioPlayerNode`'s time base can report
an unset sample rate, and `sampleTime / 0` is `.infinity` in Swift, not an error. That value flowed
out of `Deck.elapsed` into `Player.position` and from there into:
- `AVAudioFramePosition(seconds * sampleRate)` in `Deck.scheduleSegment` — **traps** on a
  non-finite double, and `scheduleSegment` raises an uncatchable ObjC exception on a negative
  start frame;
- SwiftUI `frame`/`Shape.trim`/`Slider` — all of which trap on a non-finite number.

Fixes (keep all): `Deck.elapsed` requires sample-time validity + a positive sample rate and
returns 0 otherwise; `scheduleSegment` clamps into the file before converting; `Player.duration`
and every published fraction go through `Player.fraction` (**`min`/`max` do NOT sanitize NaN —
`min(NaN, 1)` is NaN**); `seek` rejects non-finite targets; the 1 Hz countdown clamps before
`Int(_:)`. Pinned by `PlaybackTests/PlayerClockSafetyTests`. Also: the session opts out of system
alert interruptions, and the stem model download is size-validated before being cached (a cut-off
transfer or a captive-portal page used to be cached as "the model" forever).

### UI architecture decisions
- **20 Hz `position` writes must not reach heavy views**: only leaf views
  (`TrackProgressRing`, `ScrubberBar`, `MiniProgressLine`) read `player.position` /
  `player.displayProgress`; parent bodies (which host the backdrop) never re-evaluate on tick.
- **Backdrop** (`Theme.swift`): hybrid palette-gradient (CIAreaAverage top/bottom, tone-mapped)
  + blurred-art layer (160px working image, sigma 16, opacity 0.55, mask fade), cached per-URL
  in NSCache as `BackdropStyle`. Never reintroduce live `.blur(radius: 60)` on full-screen
  `AsyncImage` — offscreen-render churn contributed to memory pressure.
- **Vertical pager** (`MainPagerView`): pages tile exactly one screen via
  `containerRelativeFrame` + `ignoresSafeArea`; safe-area is re-applied per page as HARD
  padding, and full-bleed surfaces are page `.background`s behind that padding.
  NavigationStack bars and `safeAreaPadding` do NOT behave inside scroll content — that's why
  it's built this way (black bars / status-bar overlap regressions otherwise).
  **The pager's `GeometryReader` sits INSIDE the safe area while its ScrollView ignores it**, so
  `proxy.size.height` is short by exactly the insets it reports, and every page's
  `containerRelativeFrame(.vertical)` is the full window height. `pageHeight` must therefore be
  `proxy.size.height + insets.top + insets.bottom`. Measuring the shared backdrop with the short
  value is what put flat `systemGroupedBackground` (black in dark mode) bands at the top and
  bottom and slid the album gradient out of register with Now Playing.
- **Transitions**: skip button starts a 5s blend (`Player.skipTransitionDurationSeconds`),
  clamped to remaining audio (`effectiveEndSeconds - position`; hard-advance under 1s) so short
  tracks don't end in an audible cut. `isUserInitiatedSkipTransition` prevents double-spend.
  `Player.displayProgress` blends outgoing/incoming fractions by `transitionProgress` so
  progress UI glides across song changes.
- `Player.prepare`/`restore` stay **metadata-only** (no engine build, no `notifyUpcoming()`)
  — see AGENTS.md jetsam gotcha.

### Playlist import "spins forever, then orange retry" (Sept 2026, resolved)
Every imported track resolved fine, then every ranged download got HTTP 403 → mapped to
`streamURLExpired` → re-resolve → 403 again → `scheduleRetry` kept the row `.pending` through
5 whole-track attempts (minutes of spinner) → `.failed`. Root cause: the pinned YouTubeKit
(7cc8190, July) fetched stream URLs via the ANDROID_VR InnerTube client, which YouTube stopped
serving past the first chunk in mid-August 2026. Fix: pin YouTubeKit `exact: "0.4.9"`
(visionOS/web clients + embed fallback). Verified with the opt-in live probe test on the
simulator: 0/8 tracks ready before, 8/8 after (full files, BPM analysed). See the AGENTS.md
gotcha for the diagnosis recipe.

### Catalog search (PR #108)
iTunes Search API (no key) for songs/albums; custom in-app keyboard with
`CatalogAutocorrect` (ContinuityCore, Linux-tested) learning vocabulary from results + the
user's library. Songs → "From Search" playlist; albums → imported playlists. Both ride the
existing `searchQuery` → YouTube ingest path.

## CI / TestFlight operations

- `.github/workflows/core-tests.yml`: assembles the non-Accelerate ContinuityCore subset and
  runs `swift test` on Linux for every PR. New pure Core files + tests are picked up
  automatically (keep them Accelerate-free or add them to the exclusion list).
- `.github/workflows/testflight.yml`: on every push to `main` (+ `workflow_dispatch`), builds
  on `macos-26` with **cloud signing** — no certs/profiles in the repo. Secrets: `ASC_KEY_ID`
  / `ASC_ISSUER_ID` / `ASC_KEY_P8` (base64 .p8). The API key **must be Admin role** — an App
  Manager key fails with "Cloud signing permission error / No profiles for
  'com.sanylax.continuity'". Build number = `github.run_number`; export method
  `app-store-connect`, destination `upload`, team `KP832RV67A`. Internal testers get builds
  automatically after processing.
- Known failure modes already hit: App-Manager-role key (fixed — Admin key created);
  empty/placeholder secrets from copy-pasted commands; **ITMS error 90382 "Upload limit
  reached"** = Apple's per-app daily cap — wait for the 24h window, nothing to fix.
- App Store Connect still has a legacy **Xcode Cloud "Archive – iOS"** workflow producing
  `action_required` checks on PRs; it's ASC-side, unrelated to code, and competes for upload
  quota — worth disabling in ASC.

## App Store track

Branch `appStoreReleaseCandidate` (PR #104) is the shippable variant: YouTube downloading and
its external packages removed; "+" imports local audio files (`.fileImporter`, "My Music"
playlist, `Track.stemKey = youtubeVideoID ?? id.uuidString`). Remaining v1 items (not started
unless asked): `PrivacyInfo.xcprivacy`, ASC metadata (privacy policy/support URLs,
screenshots), accessibility-label pass, `DEVELOPMENT_TEAM` removal from project.yml.

## Performance invariants (from the perf + Liquid Glass audit)

Each of these was a measured cost, not a style preference. Don't undo them.

- **Nothing on the 20 Hz tick path but leaves.** `position`, `transitionProgress` and anything
  derived from them (`secondsUntilTransition`, `displayProgress`) may only be read by tiny leaf
  views: `TrackProgressRing`, `ScrubberBar`, `MiniProgressLine`, `BlendPlayhead`,
  `TransitionCountdownPill`. The Now Playing transition panel used to read the countdown, so
  every tick re-ran `TransitionPreview.make`, re-read both tracks' `beatTimes` out of SwiftData
  and redrew two Canvases. `Player.transitionCountdownSeconds` publishes the countdown at 1 Hz
  for exactly this reason; `TransitionVisualizationView` resolves beat positions and curve
  samples once in `init`.
- **A row's now-playing highlight is read by the row, never passed in.** As a parameter it makes
  every track change invalidate the list's parent, which re-sorts the whole playlist.
- **Cache directories are `static let`.** `AudioCache`/`StemCache`/`ArtworkStore.directory` are
  read per artwork URL, per row, per frame; as computed properties each read ran
  `createDirectory` + `setResourceValues`.
- **All artwork goes through `ArtworkImageStore`** (shared bounded decode cache + ImageIO
  downsampling), never `AsyncImage`, which caches nothing and re-decodes per row. Backdrop
  renders are coalesced per URL and share one `CIContext`; results are NSCache-bounded, so they
  can't accumulate the way the old dictionary did. Any load shared this way outlives a single
  view's task, so check `Task.isCancelled` before assigning the result.
- **Bulk filesystem work is batched and off the main actor**: one directory listing per cache
  (`CacheIndex`) instead of per-track `fileExists` probes, cleanup sweeps in detached tasks, and
  stem-cache budget passes coalesced (`scheduleBudgetPass`) rather than one full scan per skip.
- **Launch fetches that only need ids use `propertiesToFetch`** — a plain `FetchDescriptor<Track>`
  hydrates every row's `beatTimes`.
- **Liquid Glass is the real API, everywhere.** `glassEffect` via `continuityGlass` /
  `continuityGlassCapsule` — no `Material` stand-ins, no hand-drawn hairlines. Groups of glass
  elements (the keyboard's key grid, the transition chips) sit in a `GlassEffectContainer` with
  `spacing: 0` so they composite in one pass without merging into blobs, and glass is never
  layered directly on glass (the keyboard plane stays an opaque fill).
- `CatalogAutocorrect` and `LoudnessMeter` are allocation-/division-light on purpose; both have
  differential checks behind them (identical suggestions over thousands of fuzzed queries;
  bit-identical LUFS). Re-verify the same way before changing their loops.

## Known issues (noted during the audits, deliberately not fixed)

1. `StreamingStereoDecoder` treats mono sources as dual-mono aliases.
2. `runStreaming` uses O(n) `removeFirst(n)` per window — ~344 KB memmove per window against a
   transformer inference, so it stays measurement noise. Memory fine.
3. `separateStems` pins `@Model track` + `ModelContext` across minutes-long tasks.
4. Manual `syncAll` bypasses auto-sync's failure backoff (deliberate — it means "now").
5. `SearchResultsView` still rescans on each keystroke; it no longer sorts, and no longer reruns
   on track changes, so the remaining cost is one `localizedCaseInsensitiveContains` pass.
6. `AudioStack.init` force-unwraps `AVAudioFormat(...)` — cannot fail for 44.1 kHz stereo.
7. `Deck.load` opens `AVAudioFile`s on the main actor at every track change and blend start
   (a few ms); moving it off would have to keep node scheduling ordered.
8. `ToneSynth.makeLoop` synthesizes ~1M `sin` calls per demo-track load. Caching the buffers
   would cost 2.8 MB each — the wrong trade for this app; demo tracks only.

## Debugging on device (the owner can run these)

- Console filter: subsystem `com.continuity.app` (breadcrumbs use category `mem`, prefix
  `mem[...]`; playback heartbeat is `mem[playback]` every ~10s).
- Jetsam reports: Settings → Privacy & Security → Analytics Data → `JetsamEvent-*.ips`
  (memory kills) vs `Continuity-*.ips` (crashes — check for SIGABRT +
  `AVAudioPlayerNode play(at:)`).
