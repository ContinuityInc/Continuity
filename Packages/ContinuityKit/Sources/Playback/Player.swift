import AVFoundation
import Domain
import Observation
import ContinuityCore
import os

extension Logger {
    /// Audio-engine lifecycle breadcrumbs (interruptions, route changes, recoveries) — the
    /// events behind "transient" playback failures, so they must be visible in the field.
    static let audio = Logger(subsystem: "com.continuity.app", category: "audio")
}

/// The CoreAudio-touching half of the player: engine + both decks, wired as one graph. Built
/// lazily by `Player.ensureAudioStack()` — never at init — because the first `mainMixerNode`
/// access is the app's first CoreAudio RPC, and on a wedged audio server that RPC times out and
/// aborts in-process (AURemoteIO `_ReportRPCTimeout` → SIGABRT, uncatchable). Deferral shrinks
/// that blast radius from "app won't launch" to "pressing play fails".
@MainActor
final class AudioStack {
    let engine = AVAudioEngine()
    let deckA: Deck
    let deckB: Deck
    /// The deck playing the current track. The other (`idle`) hosts the incoming track during a blend.
    var current: Deck
    var idle: Deck { current === deckA ? deckB : deckA }

    init() {
        let synthFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        deckA = Deck(engine: engine, mainMixer: engine.mainMixerNode, synthFormat: synthFormat)
        deckB = Deck(engine: engine, mainMixer: engine.mainMixerNode, synthFormat: synthFormat)
        current = deckA
    }
}

/// Dual-deck playback engine with configurable equal-power crossfades between tracks (M2).
///
/// Owns one `AVAudioEngine` with two `Deck`s (via the lazily-built `AudioStack`). As the current
/// track nears its end, the next track is started on the idle deck and the two are crossfaded
/// using gains from the unit-tested `TransitionPlan` / `CrossfadeCurve`. That overlap is what
/// makes track changes "smooth".
///
/// The blend is driven by the **incoming** deck's clock so it can never get stuck if the outgoing
/// file drains early. M3 will refine *when* and *how* (beat-aligned starts, tempo matching).
@MainActor
@Observable
public final class Player {
    // MARK: Observable state
    var queue: [Track] = []
    var currentIndex = 0
    public internal(set) var isPlaying = false
    public internal(set) var isTransitioning = false
    /// 0→1 progress of the in-flight blend, for the Now Playing blend meter. 0 when idle.
    public internal(set) var transitionProgress: Double = 0
    /// Seconds into the current track (drives the scrubber + clock).
    public var position: TimeInterval = 0
    /// User-configurable crossfade settings (edited by `TransitionSettingsView`). Persisted on
    /// every edit and restored at launch, like the playback session itself.
    public var transitionSettings = TransitionSettings.loadPersisted() {
        didSet {
            transitionSettings.persist()
            // Loudness leveling applies at deck-load time; retro-apply the toggle immediately.
            if oldValue.loudnessLevelingEnabled != transitionSettings.loudnessLevelingEnabled,
               let audio {
                applyLoudness(to: audio.current)
                if isTransitioning { applyLoudness(to: audio.idle) }
            }
        }
    }

    public var currentTrack: Track? { queue.indices.contains(currentIndex) ? queue[currentIndex] : nil }
    /// The track being blended in during a transition (drives the Now Playing "blending into…").
    public var incomingTrack: Track? {
        isTransitioning && queue.indices.contains(transitionTargetIndex) ? queue[transitionTargetIndex] : nil
    }
    /// Never zero while a track is loaded — uses the deck's resolved duration, falling back to the
    /// model whenever no deck is loaded (pre-audio staging, or before the first load).
    public var duration: TimeInterval {
        if let deck = audio?.current, deck.loadedDuration > 0 { return deck.loadedDuration }
        return currentTrack?.durationSeconds ?? 0
    }

    // MARK: Engine / decks
    /// All CoreAudio state, or nil until the first real audio need (see `ensureAudioStack()`).
    var audio: AudioStack?
    /// Seek staged before the audio stack exists (session restore, paused pre-audio scrubs).
    /// Applied — exactly once — when the staged track first loads onto a deck.
    var pendingSeekSeconds: TimeInterval?

    private var displayTimer: Timer?
    /// Clock baseline, so `position` can be offset for synth seeks.
    var baselineSeconds: TimeInterval = 0
    /// Queue index the in-flight transition is moving to.
    var transitionTargetIndex = 0
    /// Seconds the incoming deck was seeked into its track for beat alignment — becomes the
    /// promoted deck's clock baseline when the transition completes.
    var incomingStartOffset: TimeInterval = 0
    /// Low-shelf cut (dB) applied to the incoming deck's low end at the start of a bass-swap blend,
    /// ramped back to flat over the first part of the transition.
    let bassSwapCutDB: Float = -9
    /// Harmonic-mixing pitch shift (semitones) applied to the CURRENT track, so the next
    /// transition compares keys against what's actually sounding, not the stored analysis.
    var currentPitchShiftSemitones = 0
    /// Pitch shift staged on the incoming deck; promoted to `currentPitchShiftSemitones` when the
    /// transition completes.
    var incomingPitchShiftSemitones = 0

    /// True when playback was paused by an interruption/route change and should resume when the
    /// system says the coast is clear.
    var resumeAfterInterruption = false

    /// Publishes state to the lock screen / Control Center and routes remote commands back here.
    let nowPlayingBridge = NowPlayingBridge()

    /// Called with the current track + the next few whenever the play position moves — the ingest
    /// layer uses it to prepare stems just-in-time (separating a whole library eagerly is
    /// CPU-hours and gigabytes; the blend only ever needs the neighborhood).
    public var onUpcomingTracks: (([Track]) -> Void)?

    /// Resolves history IDs (oldest first) to live tracks when the queue runs dry; the app
    /// supplies storage lookup. Return order is preserved; missing tracks simply dropped.
    /// Repeats collapse to first occurrence (replaceUpcoming dedupes), so the loop order tracks
    /// the oldest surviving entries — the 200-cap trim may rotate the loop start over long sessions.
    public var onQueueExhausted: (([UUID]) -> [Track])?

    /// One refill attempt per current track — an empty/failed refill must not retry every tick.
    /// Reset wherever the current track changes (startCurrentFresh, finishTransition, prepare).
    var queueRefillAttempted = false

    /// How far ahead stems are prepared. At ~2–4 min per separation and ~3.5 min per song, three
    /// tracks of lead time keeps the next blend's stems ready even right after a skip.
    private static let upcomingStemWindow = 3

    /// Reports the play-position neighborhood to `onUpcomingTracks`.
    func notifyUpcoming() {
        guard !queue.isEmpty, queue.indices.contains(currentIndex) else { return }
        let count = min(Player.upcomingStemWindow, queue.count)
        let tracks = (0..<count).map { queue[(currentIndex + $0) % queue.count] }
        onUpcomingTracks?(tracks)
    }

    /// Deliberately RPC-free: no AVFAudio objects, no AVAudioSession calls. A wedged CoreAudio
    /// server must not be able to stop the app from launching (see `AudioStack`).
    public init() {
        nowPlayingBridge.configure(player: self)
    }

    /// Single funnel that materializes the audio stack: constructs engine + decks (wiring the
    /// graph), activates the session, and registers the interruption/route-change observers
    /// (their handlers reference the engine, so they can't exist before it).
    ///
    /// Every deck/engine operation is reachable only through one of these builders — nothing may
    /// touch a deck first, because scheduling on an unattached node throws an ObjC exception:
    ///   - play(tracks:) / next() / previous() / hardAdvance() → startCurrentFresh()
    ///   - togglePlayPause() play direction (incl. remotePlay / lock screen) → ensureCurrentLoaded()
    ///   - seek() with a live deck → ensureRunning() (paused pre-audio scrubs stay metadata-only)
    ///   - beginTransition() → called here directly (tick() only runs while playing, post-build)
    ///   - recoverPlayback() / pauseForEnvironment() → observers are only registered here, so
    ///     they cannot fire pre-build
    ///   - handleDeleted() / prepare() / restore() / persistState() never build — they guard on
    ///     `audio` existing instead.
    @discardableResult
    func ensureAudioStack() -> AudioStack {
        if let audio { return audio }
        let stack = AudioStack()
        audio = stack
        configureSession()
        observeAudioEnvironment(engine: stack.engine)
        Logger.audio.info("audio graph wired")
        return stack
    }

    /// First-playback funnel: builds the stack, starts the engine, loads the staged current track
    /// onto the current deck if it isn't already there, and applies any pending staged seek
    /// exactly once. Returns false when there's nothing to play or the engine won't start.
    @discardableResult
    func ensureCurrentLoaded() -> Bool {
        guard let track = currentTrack else { return false }
        let audio = ensureAudioStack()
        guard ensureRunning() else { return false }
        if audio.current.track?.id != track.id {
            audio.current.load(track)
            applyLoudness(to: audio.current)
            currentPitchShiftSemitones = 0
        }
        if let pending = pendingSeekSeconds {
            pendingSeekSeconds = nil
            if pending > 0, audio.current.seekRealFile(to: pending) {
                baselineSeconds = pending
            } else {
                // Synth deck: looped audio is identical at any offset, so just move the clock.
                baselineSeconds = pending - audio.current.elapsed
            }
            position = pending
        }
        // First real audio need (play from a prepare/restore staging) — start JIT stems here,
        // not at launch. prepare() deliberately skips notifyUpcoming to avoid ORT jetsam.
        notifyUpcoming()
        return true
    }

    /// Explicit play/pause for remote commands (lock screen, AirPods) — the system sends the
    /// intended state, so these must not blindly toggle if we're already there.
    func remotePlay() { if !isPlaying { togglePlayPause() } }
    func remotePause() { if isPlaying { togglePlayPause() } }

    /// Sets a deck's loudness-leveling makeup gain from its track's measured loudness: every
    /// track meets the blend at a common level (−14 LUFS target) instead of lurching between
    /// quiet and loud masters. No measurement (or leveling off) → unity gain.
    func applyLoudness(to deck: Deck) {
        guard transitionSettings.loudnessLevelingEnabled, let lufs = deck.track?.loudnessLUFS else {
            deck.loudnessGain = 1
            return
        }
        let gainDB = LoudnessMeter.makeupGainDB(measuredLUFS: lufs)
        deck.loudnessGain = Float(pow(10, gainDB / 20))
    }

    // MARK: Skip budget + history

    /// Radio-style forward-skip budget: `next()` spends one; finishing a track naturally earns
    /// one back (capped). Previous-skips are unlimited and walk the persistent play history.
    static let maxSkips = 3
    public internal(set) var skipsRemaining = Player.maxSkips
    /// IDs of previously played tracks, most recent last. Persisted, so "previous" works across
    /// launches.
    var historyIDs: [UUID] = []
    /// Ticks since the last periodic state save (persist every ~5 s while playing).
    private var ticksSincePersist = 0

    // MARK: Internals

    /// Index of the next track for *auto-advance* (no wrap-around — a playlist stops at its end).
    private var nextIndex: Int? {
        let n = currentIndex + 1
        return queue.indices.contains(n) ? n : nil
    }

    func ensureRunning() -> Bool {
        let audio = ensureAudioStack()
        if audio.engine.isRunning { return true }
        try? AVAudioSession.sharedInstance().setActive(true)
        do { try audio.engine.start(); return true } catch { return false }
    }

    /// Starts the current track from scratch on the current deck (play / next / previous / restart).
    func startCurrentFresh() {
        guard let track = currentTrack else { return }
        let audio = ensureAudioStack()
        audio.idle.stop()
        audio.current.stop()
        audio.current.volume = 1
        pendingSeekSeconds = nil   // a fresh start supersedes any staged restore-seek
        guard ensureRunning() else { isPlaying = false; stopTimer(); return }
        audio.current.load(track)   // load() resets rate/pitch, so the fresh track plays true
        applyLoudness(to: audio.current)
        currentPitchShiftSemitones = 0
        queueRefillAttempted = false   // new current track earns a fresh exhaustion refill
        baselineSeconds = 0
        position = 0
        audio.current.play()
        isPlaying = true
        resumeAfterInterruption = false   // an explicit (re)start supersedes any pending auto-resume
        startTimer()
        notifyUpcoming()
    }

    func startTimer() {
        stopTimer()
        // 20 Hz: smooth enough for the volume ramp and the scrubber.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    func stopTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    /// The moment transitions treat as the current track's end. With silence trimming on, that's
    /// the last audible moment (gapless) rather than the file's end — a blend into trailing
    /// silence reads as a gap. Falls back to the full duration when unscanned or disabled.
    private var effectiveEndSeconds: TimeInterval {
        let full = duration
        // Pre-audio the staged track carries the same trim metadata as the loaded deck would.
        let track = audio?.current.track ?? currentTrack
        guard transitionSettings.trimSilenceEnabled,
              let audibleEnd = track?.audibleEndSeconds,
              audibleEnd > 1, audibleEnd < full else { return full }
        return audibleEnd
    }

    private func tick() {
        guard isPlaying, let audio else { return }
        let elapsed = baselineSeconds + audio.current.elapsed
        position = elapsed
        // Periodic save (~5 s) so a kill/crash resumes near the right spot next launch.
        ticksSincePersist += 1
        if ticksSincePersist >= 100 {
            ticksSincePersist = 0
            persistState()
        }
        let dur = effectiveEndSeconds
        let plan = TransitionPlan(curve: transitionSettings.curve, duration: transitionSettings.durationSeconds)

        if isTransitioning {
            // Drive the blend off the INCOMING deck's clock — it keeps advancing even after the
            // outgoing file drains, so the transition can never get stuck half-faded.
            let incomingElapsed = audio.idle.elapsed
            let gains = plan.gains(position: incomingElapsed, startPosition: 0)
            audio.current.volume = Float(gains.outgoing)
            audio.idle.volume = Float(gains.incoming)
            let progress = plan.progress(position: incomingElapsed, startPosition: 0)
            transitionProgress = progress
            // Bass-swap: fade the incoming low end in so two basslines don't stack into mud.
            if transitionSettings.bassSwapEnabled {
                applyBassSwap(progress: progress)
            }
            // When both decks have stems, shape the per-stem gains so the outgoing vocals duck out
            // under the incoming track — the M4 flagship "vocal-aware" blend.
            if audio.current.hasStems && audio.idle.hasStems {
                applyVocalHandling(progress: progress)
            }
            if plan.isComplete(position: incomingElapsed, startPosition: 0) {
                finishTransition()
            }
        } else if let next = nextIndex {
            if plan.shouldStart(position: elapsed, trackDuration: dur, hasNextTrack: true) {
                beginTransition(toIndex: next, outgoingPosition: elapsed)
            } else if dur > 0 && elapsed >= dur - 0.05 {
                // Reached the end without a crossfade (blend off, or track too short to blend) → hard cut.
                hardAdvance(toIndex: next)
            }
        } else if !queueRefillAttempted {
            // Queue about to run dry: refill upcoming from the listening history on the FIRST
            // tick that sees it, not at the end — the transition plan needs a next track to
            // schedule the blend, and replaceUpcoming's notifyUpcoming gives the stem pipeline
            // lead time to prep the loop's first track. Once per track; if nothing comes back,
            // later ticks fall through to the stop-at-end below.
            queueRefillAttempted = true
            // Empty history (fresh install, single demo) skips the provider entirely — its
            // lookup shouldn't cost a library fetch just to resolve zero IDs.
            if !historyIDs.isEmpty, let refill = onQueueExhausted?(historyIDs), !refill.isEmpty {
                replaceUpcoming(with: refill)
            }
        } else if dur > 0 && elapsed >= dur - 0.05 {
            // Last track and no history to loop into: stop at the end (resume will restart it).
            stopPlayback()
        }
    }

}
