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
- **Transitions**: skip button starts a 5s blend (`Player.skipTransitionDurationSeconds`),
  clamped to remaining audio (`effectiveEndSeconds - position`; hard-advance under 1s) so short
  tracks don't end in an audible cut. `isUserInitiatedSkipTransition` prevents double-spend.
  `Player.displayProgress` blends outgoing/incoming fractions by `transitionProgress` so
  progress UI glides across song changes.
- `Player.prepare`/`restore` stay **metadata-only** (no engine build, no `notifyUpcoming()`)
  — see AGENTS.md jetsam gotcha.

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

## Known issues (noted during the OOM audit, deliberately not fixed)

1. `LoudnessMeter.integratedLUFS` allocates a full-length `[Double]` buffer (~127 MB / 6 min).
2. `StreamingStereoDecoder` treats mono sources as dual-mono aliases.
3. `runStreaming` uses O(n) `removeFirst(n)` per window (CPU churn, memory fine).
4. `separateStems` pins `@Model track` + `ModelContext` across minutes-long tasks.
5. `ensureStems` spawns overlapping `enforceBudget` passes on rapid skips.
6. Manual `syncAll` bypasses auto-sync's failure backoff.
7. `onQueueExhausted`/`restorePlaybackSession` fetch every Track incl. `beatTimes`.
8. `SearchResultsView` recomputes matches per keystroke without memoization.
9. `AudioStack.init` force-unwraps `AVAudioFormat(...)`.
10. `NowPlayingBridge` can briefly blank lock-screen artwork when a fetch is superseded.

## Debugging on device (the owner can run these)

- Console filter: subsystem `com.continuity.app` (breadcrumbs use category `mem`, prefix
  `mem[...]`; playback heartbeat is `mem[playback]` every ~10s).
- Jetsam reports: Settings → Privacy & Security → Analytics Data → `JetsamEvent-*.ips`
  (memory kills) vs `Continuity-*.ips` (crashes — check for SIGABRT +
  `AVAudioPlayerNode play(at:)`).
