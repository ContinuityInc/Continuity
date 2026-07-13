import AVFoundation
import Observation
import ContinuityCore
import os

extension Logger {
    /// Audio-engine lifecycle breadcrumbs (interruptions, route changes, recoveries) — the
    /// events behind "transient" playback failures, so they must be visible in the field.
    static let audio = Logger(subsystem: "com.continuity.app", category: "audio")
}

/// Dual-deck playback engine with configurable equal-power crossfades between tracks (M2).
///
/// Owns one `AVAudioEngine` with two `Deck`s. As the current track nears its end, the next track
/// is started on the idle deck and the two are crossfaded using gains from the unit-tested
/// `TransitionPlan` / `CrossfadeCurve`. That overlap is what makes track changes "smooth".
///
/// The blend is driven by the **incoming** deck's clock so it can never get stuck if the outgoing
/// file drains early. M3 will refine *when* and *how* (beat-aligned starts, tempo matching).
@MainActor
@Observable
final class Player {
    // MARK: Observable state
    private(set) var queue: [Track] = []
    private(set) var currentIndex = 0
    private(set) var isPlaying = false
    private(set) var isTransitioning = false
    /// 0→1 progress of the in-flight blend, for the Now Playing blend meter. 0 when idle.
    private(set) var transitionProgress: Double = 0
    /// Seconds into the current track (drives the scrubber + clock).
    var position: TimeInterval = 0
    /// User-configurable crossfade settings (edited by `TransitionSettingsView`).
    var transitionSettings = TransitionSettings.default

    var currentTrack: Track? { queue.indices.contains(currentIndex) ? queue[currentIndex] : nil }
    /// The track being blended in during a transition (drives the Now Playing "blending into…").
    var incomingTrack: Track? {
        isTransitioning && queue.indices.contains(transitionTargetIndex) ? queue[transitionTargetIndex] : nil
    }
    /// Never zero while a track is loaded — uses the deck's resolved duration, falling back to the
    /// model only for the brief window before the first load.
    var duration: TimeInterval {
        currentDeck.loadedDuration > 0 ? currentDeck.loadedDuration : (currentTrack?.durationSeconds ?? 0)
    }

    // MARK: Engine / decks
    private let engine = AVAudioEngine()
    private let synthFormat: AVAudioFormat
    private let deckA: Deck
    private let deckB: Deck
    /// The deck playing the current track. The other (`idleDeck`) hosts the incoming track during a blend.
    private var currentDeck: Deck
    private var idleDeck: Deck { currentDeck === deckA ? deckB : deckA }

    private var displayTimer: Timer?
    /// Clock baseline, so `position` can be offset for synth seeks.
    private var baselineSeconds: TimeInterval = 0
    /// Queue index the in-flight transition is moving to.
    private var transitionTargetIndex = 0
    /// Seconds the incoming deck was seeked into its track for beat alignment — becomes the
    /// promoted deck's clock baseline when the transition completes.
    private var incomingStartOffset: TimeInterval = 0
    /// Low-shelf cut (dB) applied to the incoming deck's low end at the start of a bass-swap blend,
    /// ramped back to flat over the first part of the transition.
    private let bassSwapCutDB: Float = -9
    /// Harmonic-mixing pitch shift (semitones) applied to the CURRENT track, so the next
    /// transition compares keys against what's actually sounding, not the stored analysis.
    private var currentPitchShiftSemitones = 0
    /// Pitch shift staged on the incoming deck; promoted to `currentPitchShiftSemitones` when the
    /// transition completes.
    private var incomingPitchShiftSemitones = 0

    /// True when playback was paused by an interruption/route change and should resume when the
    /// system says the coast is clear.
    private var resumeAfterInterruption = false

    /// Publishes state to the lock screen / Control Center and routes remote commands back here.
    private let nowPlayingBridge = NowPlayingBridge()

    /// Called with the current track + the next few whenever the play position moves — the ingest
    /// layer uses it to prepare stems just-in-time (separating a whole library eagerly is
    /// CPU-hours and gigabytes; the blend only ever needs the neighborhood).
    var onUpcomingTracks: (([Track]) -> Void)?

    /// How far ahead stems are prepared. At ~2–4 min per separation and ~3.5 min per song, three
    /// tracks of lead time keeps the next blend's stems ready even right after a skip.
    private static let upcomingStemWindow = 3

    /// Reports the play-position neighborhood to `onUpcomingTracks`.
    private func notifyUpcoming() {
        guard !queue.isEmpty, queue.indices.contains(currentIndex) else { return }
        let count = min(Player.upcomingStemWindow, queue.count)
        let tracks = (0..<count).map { queue[(currentIndex + $0) % queue.count] }
        onUpcomingTracks?(tracks)
    }

    init() {
        synthFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        deckA = Deck(engine: engine, mainMixer: engine.mainMixerNode, synthFormat: synthFormat)
        deckB = Deck(engine: engine, mainMixer: engine.mainMixerNode, synthFormat: synthFormat)
        currentDeck = deckA
        configureSession()
        observeAudioEnvironment()
        nowPlayingBridge.configure(player: self)
    }

    /// Explicit play/pause for remote commands (lock screen, AirPods) — the system sends the
    /// intended state, so these must not blindly toggle if we're already there.
    func remotePlay() { if !isPlaying { togglePlayPause() } }
    func remotePause() { if isPlaying { togglePlayPause() } }

    // MARK: Audio-environment resilience

    /// The system stops the engine on interruptions (calls, Siri), route changes (headphones,
    /// output-device switches), and configuration resets. Untreated, the next deck call throws an
    /// ObjC exception — the classic "transient" crash. These observers turn those events into a
    /// clean pause + reschedule-and-resume instead.
    private func observeAudioEnvironment() {
        let center = NotificationCenter.default

        center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let options = AVAudioSession.InterruptionOptions(
                rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            )
            MainActor.assumeIsolated {
                switch type {
                case .began:
                    Logger.audio.info("interruption began — pausing")
                    self?.pauseForEnvironment()
                case .ended where options.contains(.shouldResume):
                    Logger.audio.info("interruption ended — resuming")
                    self?.recoverPlayback()
                default:
                    break
                }
            }
        }

        center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            MainActor.assumeIsolated {
                // Headphones unplugged / output vanished: pause (standard platform UX). Other
                // route changes are handled by the configuration-change recovery below.
                if reason == .oldDeviceUnavailable {
                    Logger.audio.info("audio route lost — pausing")
                    self?.pauseForEnvironment()
                }
            }
        }

        center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // The engine stopped itself to apply a new configuration (sample rate/route).
                // Node schedules are gone; reschedule from the current position and keep going.
                guard let self, self.isPlaying else { return }
                Logger.audio.info("engine configuration change — recovering playback")
                self.recoverPlayback(force: true)
            }
        }
    }

    /// Clean pause in response to the environment (vs. the user's pause button): remembers that
    /// playback should resume if the system later allows it.
    private func pauseForEnvironment() {
        guard isPlaying else { return }
        resumeAfterInterruption = true
        cancelTransition()   // blend state won't survive an engine stop; finish cleanly
        currentDeck.pause()  // engine-state-guarded; no-ops if the engine is already down
        isPlaying = false
        stopTimer()
        persistState()       // lock screen should show paused immediately
    }

    /// Restarts the engine and reschedules the current track at the current position. `force`
    /// recovers even without a preceding `pauseForEnvironment` (configuration changes stop the
    /// engine without an interruption notification).
    private func recoverPlayback(force: Bool = false) {
        guard force || resumeAfterInterruption else { return }
        resumeAfterInterruption = false
        guard currentTrack != nil else { return }
        guard ensureRunning() else {
            Logger.audio.error("engine restart failed during recovery")
            isPlaying = false
            stopTimer()
            return
        }
        // Engine stops invalidate node schedules — reschedule from where the clock stood.
        if currentDeck.seekRealFile(to: position) {
            baselineSeconds = position
            currentDeck.play()
            isPlaying = true
            startTimer()
        } else {
            // Synth deck: the loop is position-agnostic; a fresh start is equivalent.
            startCurrentFresh()
        }
        persistState()       // lock screen should show playing again after recovery
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    // MARK: Skip budget + history

    /// Radio-style forward-skip budget: `next()` spends one; finishing a track naturally earns
    /// one back (capped). Previous-skips are unlimited and walk the persistent play history.
    static let maxSkips = 3
    private(set) var skipsRemaining = Player.maxSkips
    /// IDs of previously played tracks, most recent last. Persisted, so "previous" works across
    /// launches.
    private var historyIDs: [UUID] = []
    /// Ticks since the last periodic state save (persist every ~5 s while playing).
    private var ticksSincePersist = 0

    /// Records that we're leaving `track` by moving forward, so previous() can come back to it.
    private func pushHistory(_ track: Track?) {
        guard let track else { return }
        historyIDs.append(track.id)
        if historyIDs.count > 200 { historyIDs.removeFirst(historyIDs.count - 200) }
    }

    /// Saves the full playback session (queue, position, skips, history) for the next launch,
    /// and mirrors the same state to the lock screen / Control Center. Every playback
    /// discontinuity funnels through here, which is exactly when both need updating.
    private func persistState() {
        nowPlayingBridge.update(
            track: currentTrack,
            duration: duration,
            position: position,
            isPlaying: isPlaying,
            skipsRemaining: skipsRemaining
        )
        guard !queue.isEmpty else { return }
        PlaybackStateStore.save(PersistedPlaybackState(
            queueTrackIDs: queue.map(\.id),
            currentIndex: currentIndex,
            positionSeconds: position,
            skipsRemaining: skipsRemaining,
            historyTrackIDs: historyIDs
        ))
    }

    // MARK: Transport

    func play(tracks: [Track], startAt index: Int) {
        cancelTransition()
        pushHistory(currentTrack)
        queue = tracks
        currentIndex = max(0, min(index, tracks.count - 1))
        startCurrentFresh()
        persistState()
    }

    /// Like `play(tracks:startAt:)` but left paused at the start — used to stage the session's
    /// first track on the Now Playing screen without blasting audio at launch.
    func prepare(tracks: [Track], startAt index: Int) {
        cancelTransition()
        queue = tracks
        currentIndex = max(0, min(index, tracks.count - 1))
        guard let track = currentTrack else { return }
        idleDeck.stop()
        currentDeck.stop()
        currentDeck.load(track)
        currentPitchShiftSemitones = 0
        baselineSeconds = 0
        position = 0
        isPlaying = false
        persistState()
        notifyUpcoming()
    }

    /// Rebuilds the previous session from persisted state (missing tracks dropped), leaving the
    /// current track loaded and paused at its saved position.
    func restore(_ state: PersistedPlaybackState, resolving tracksByID: [UUID: Track]) {
        let tracks = state.queueTrackIDs.compactMap { tracksByID[$0] }
        guard !tracks.isEmpty else { return }
        skipsRemaining = max(0, min(Player.maxSkips, state.skipsRemaining))
        historyIDs = state.historyTrackIDs.filter { tracksByID[$0] != nil }

        // Map the saved index through any dropped tracks by following the saved current track ID.
        let savedCurrentID = state.queueTrackIDs.indices.contains(state.currentIndex)
            ? state.queueTrackIDs[state.currentIndex] : nil
        let index = savedCurrentID.flatMap { id in tracks.firstIndex { $0.id == id } } ?? 0

        prepare(tracks: tracks, startAt: index)

        // Seek to the saved spot (real files only; the synth loop is position-agnostic).
        let target = max(0, min(state.positionSeconds, duration > 0 ? duration : state.positionSeconds))
        if target > 0, currentDeck.seekRealFile(to: target) {
            baselineSeconds = target
            position = target
        }
        persistState()
    }

    func togglePlayPause() {
        guard currentTrack != nil else { return }
        if isPlaying {
            currentDeck.pause()
            if isTransitioning { idleDeck.pause() }
            isPlaying = false
            stopTimer()
        } else {
            guard ensureRunning() else { isPlaying = false; return }
            // If the queue had ended (the deck fully drained), replay from the start instead of
            // calling play() on an empty node, which would just be silent.
            if !isTransitioning, duration > 0, position >= duration - 0.05 {
                startCurrentFresh()
            } else {
                currentDeck.play()
                if isTransitioning { idleDeck.play() }
                isPlaying = true
                startTimer()
            }
        }
        persistState()
    }

    func next() {
        guard !queue.isEmpty, skipsRemaining > 0 else { return }
        skipsRemaining -= 1
        cancelTransition()
        pushHistory(currentTrack)
        currentIndex = (currentIndex + 1) % queue.count
        startCurrentFresh()
        persistState()
    }

    func previous() {
        guard !queue.isEmpty else { return }
        cancelTransition()
        // Restart the current track if we're more than 3s in; otherwise step back through the
        // play history (unlimited), falling back to the previous queue slot when history is empty
        // or refers to tracks no longer in the queue.
        if position > 3 {
            startCurrentFresh()
            return
        }
        var backIndex: Int?
        while let lastID = historyIDs.popLast() {
            if let found = queue.firstIndex(where: { $0.id == lastID }) {
                backIndex = found
                break
            }
        }
        currentIndex = backIndex ?? (currentIndex - 1 + queue.count) % queue.count
        startCurrentFresh()
        persistState()
    }

    /// Removes deleted tracks from the live queue BEFORE their SwiftData models are destroyed —
    /// a deck or queue reference to a deleted `@Model` would crash on next access. Handles every
    /// case: blend target deleted (cancel the blend), current track deleted (jump to the next
    /// surviving track, preserving play/pause state), and plain queue shrinkage (fix indices).
    func handleDeleted(trackIDs: Set<UUID>) {
        historyIDs.removeAll { trackIDs.contains($0) }
        defer { persistState() }
        guard queue.contains(where: { trackIDs.contains($0.id) }) else { return }

        // Cancel an in-flight blend if either side of it is going away.
        let targetTrack = isTransitioning && queue.indices.contains(transitionTargetIndex)
            ? queue[transitionTargetIndex] : nil
        let currentDeleted = currentTrack.map { trackIDs.contains($0.id) } ?? false
        if currentDeleted || (targetTrack.map { trackIDs.contains($0.id) } ?? false) {
            cancelTransition()
        }

        let wasPlaying = isPlaying
        let survivorsBeforeCurrent = queue.prefix(currentIndex).filter { !trackIDs.contains($0.id) }.count
        queue = queue.filter { !trackIDs.contains($0.id) }

        if currentDeleted {
            if queue.isEmpty {
                currentDeck.stop()
                idleDeck.stop()
                currentIndex = 0
                position = 0
                isPlaying = false
                stopTimer()
            } else {
                currentIndex = min(survivorsBeforeCurrent, queue.count - 1)
                startCurrentFresh()
                if !wasPlaying {
                    currentDeck.pause()
                    isPlaying = false
                    stopTimer()
                }
            }
        } else {
            currentIndex = survivorsBeforeCurrent
            if isTransitioning, let targetTrack {
                // The blend survives; re-locate its target in the shrunken queue.
                transitionTargetIndex = queue.firstIndex { $0.id == targetTrack.id } ?? currentIndex
            }
        }
    }

    func seek(to seconds: TimeInterval) {
        let clamped = max(0, min(seconds, duration))
        cancelTransition() // re-evaluate the transition window from the new position
        if currentDeck.seekRealFile(to: clamped) {
            baselineSeconds = clamped
            position = clamped
            if isPlaying {
                guard ensureRunning() else { isPlaying = false; return }
                currentDeck.play()
            }
        } else {
            // Synth deck: looped audio is identical at any offset, so just move the clock.
            baselineSeconds = clamped - currentDeck.elapsed
            position = clamped
        }
        persistState()   // saved position + lock-screen elapsed both move with the scrub
    }

    // MARK: Internals

    /// Index of the next track for *auto-advance* (no wrap-around — a playlist stops at its end).
    private var nextIndex: Int? {
        let n = currentIndex + 1
        return queue.indices.contains(n) ? n : nil
    }

    private func ensureRunning() -> Bool {
        if engine.isRunning { return true }
        try? AVAudioSession.sharedInstance().setActive(true)
        do { try engine.start(); return true } catch { return false }
    }

    /// Starts the current track from scratch on `currentDeck` (play / next / previous / restart).
    private func startCurrentFresh() {
        guard let track = currentTrack else { return }
        idleDeck.stop()
        currentDeck.stop()
        currentDeck.volume = 1
        guard ensureRunning() else { isPlaying = false; stopTimer(); return }
        currentDeck.load(track)   // load() resets rate/pitch, so the fresh track plays true
        currentPitchShiftSemitones = 0
        baselineSeconds = 0
        position = 0
        currentDeck.play()
        isPlaying = true
        startTimer()
        notifyUpcoming()
    }

    private func startTimer() {
        stopTimer()
        // 20 Hz: smooth enough for the volume ramp and the scrubber.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func stopTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    /// The moment transitions treat as the current track's end. With silence trimming on, that's
    /// the last audible moment (gapless) rather than the file's end — a blend into trailing
    /// silence reads as a gap. Falls back to the full duration when unscanned or disabled.
    private var effectiveEndSeconds: TimeInterval {
        let full = duration
        guard transitionSettings.trimSilenceEnabled,
              let audibleEnd = currentDeck.track?.audibleEndSeconds,
              audibleEnd > 1, audibleEnd < full else { return full }
        return audibleEnd
    }

    private func tick() {
        guard isPlaying else { return }
        let elapsed = baselineSeconds + currentDeck.elapsed
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
            let incomingElapsed = idleDeck.elapsed
            let gains = plan.gains(position: incomingElapsed, startPosition: 0)
            currentDeck.volume = Float(gains.outgoing)
            idleDeck.volume = Float(gains.incoming)
            let progress = plan.progress(position: incomingElapsed, startPosition: 0)
            transitionProgress = progress
            // Bass-swap: fade the incoming low end in so two basslines don't stack into mud.
            if transitionSettings.bassSwapEnabled {
                applyBassSwap(progress: progress)
            }
            // When both decks have stems, shape the per-stem gains so the outgoing vocals duck out
            // under the incoming track — the M4 flagship "vocal-aware" blend.
            if currentDeck.hasStems && idleDeck.hasStems {
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
        } else if dur > 0 && elapsed >= dur - 0.05 {
            // Last track in the queue: stop at the end (resume will restart it).
            stopPlayback()
        }
    }

    /// Starts the incoming track on the idle deck at zero gain; `tick()` then ramps the blend.
    private func beginTransition(toIndex index: Int, outgoingPosition: Double) {
        guard queue.indices.contains(index) else { return }
        let incoming = idleDeck
        incoming.load(queue[index])
        incoming.volume = 0
        incoming.rate = 1
        incomingStartOffset = 0

        // Beatmatch: when both tracks have a detected tempo and the stretch is modest, retempo the
        // incoming deck to the outgoing track so they beat together through the blend. Otherwise
        // (synth samples, missing tempo, or too large a stretch) leave rate at 1 and fall back to
        // the plain equal-power crossfade.
        var rate = 1.0
        if transitionSettings.beatmatchEnabled,
           let outBPM = currentDeck.track?.bpm,
           let inBPM = queue[index].bpm,
           let matched = BeatMath.matchRate(incomingBPM: inBPM, outgoingBPM: outBPM) {
            rate = matched
            incoming.rate = Float(matched)
        }

        // Beat-align: seek the incoming so one of its beats lands on an upcoming outgoing beat,
        // phase-locking the two grids through the blend (the "you won't notice" bit). Needs a beat
        // grid on both tracks; declines gracefully — and only when the seek lands — leaving the
        // incoming at its start otherwise.
        if transitionSettings.beatmatchEnabled,
           let outBeats = currentDeck.track?.beatTimes, !outBeats.isEmpty,
           let offset = BeatMath.incomingStartOffset(
               outgoingPosition: outgoingPosition,
               outgoingBeats: outBeats,
               incomingBeats: queue[index].beatTimes,
               rate: rate
           ), incoming.seekRealFile(to: offset) {
            incomingStartOffset = offset
        }

        // Gapless: if beat-alignment didn't already seek, skip the incoming track's leading
        // silence so the blend brings in audio, not dead air. (Beat grids start at the first
        // onsets, so an aligned seek is already past any leading silence.)
        if transitionSettings.trimSilenceEnabled, incomingStartOffset == 0,
           let audibleStart = queue[index].audibleStartSeconds, audibleStart > 0.05,
           incoming.seekRealFile(to: audibleStart) {
            incomingStartOffset = audibleStart
        }

        // Harmonic mixing: when both tracks have a detected key and they clash, nudge the incoming
        // track's pitch by ±1 semitone so it lands in a Camelot-compatible key (like DJ "key sync",
        // the shift persists for the whole track — Deck.load resets it on the next load). Compare
        // against the outgoing track's EFFECTIVE key: it may itself be playing shifted.
        incomingPitchShiftSemitones = 0
        if transitionSettings.harmonicMixingEnabled,
           let outKey = currentDeck.track?.camelotCode.flatMap(Camelot.parse),
           let inKey = queue[index].camelotCode.flatMap(Camelot.parse),
           let shift = HarmonicMix.pitchShiftSemitones(
               incoming: inKey,
               outgoing: outKey.transposed(bySemitones: currentPitchShiftSemitones)
           ), shift != 0 {
            incoming.pitchCents = Float(shift * 100)
            incomingPitchShiftSemitones = shift
        }

        // Vocal-aware setup: for instrumental-overlap / hard-swap the incoming vocals start silent
        // (they enter later); for ducking they ride in with the track.
        if incoming.hasStems {
            switch transitionSettings.vocalMode {
            case .duck: incoming.vocalsGain = 1
            case .instrumentalOverlap, .hardSwap: incoming.vocalsGain = 0
            }
        }

        // Start the incoming with its low end cut so the bass-swap has something to ramp up from
        // (avoids a low-end blip before the first tick).
        if transitionSettings.bassSwapEnabled { incoming.bassGainDB = bassSwapCutDB }

        incoming.play()
        transitionTargetIndex = index
        isTransitioning = true
    }

    /// Shapes the per-stem vocal gains during a blend per the chosen vocal mode. Only called when
    /// both decks have stems.
    private func applyVocalHandling(progress: Double) {
        switch transitionSettings.vocalMode {
        case .duck:
            // Outgoing vocals fade out over the first ~70% of the blend; incoming vocals ride in.
            currentDeck.vocalsGain = Float(max(0, 1 - progress / 0.7))
        case .instrumentalOverlap:
            // Outgoing vocals out fast; incoming vocals only enter in the second half.
            currentDeck.vocalsGain = Float(max(0, 1 - progress / 0.5))
            idleDeck.vocalsGain = Float(min(1, max(0, (progress - 0.5) / 0.5)))
        case .hardSwap:
            currentDeck.vocalsGain = progress < 0.5 ? 1 : 0
            idleDeck.vocalsGain = progress < 0.5 ? 0 : 1
        }
    }

    /// Fades the incoming deck's low end in over the first ~60% of the blend, so the two basslines
    /// don't stack into low-end mud. Only called while `bassSwapEnabled`.
    private func applyBassSwap(progress: Double) {
        idleDeck.bassGainDB = bassSwapCutDB * Float(max(0, 1 - progress / 0.6))
    }

    /// Completes the crossfade: stop the outgoing deck, promote the incoming deck to current.
    private func finishTransition() {
        let outgoing = currentDeck
        let incoming = idleDeck
        outgoing.stop()
        outgoing.volume = 1
        outgoing.vocalsGain = 1
        outgoing.bassGainDB = 0
        incoming.volume = 1
        incoming.vocalsGain = 1
        incoming.bassGainDB = 0
        // The outgoing track played to its natural end — earn one forward skip back (capped),
        // and remember it in the history for unlimited previous-skips.
        skipsRemaining = min(Player.maxSkips, skipsRemaining + 1)
        pushHistory(currentTrack)
        currentDeck = incoming
        currentIndex = transitionTargetIndex
        // The incoming was seeked `incomingStartOffset` in for beat alignment, so its deck clock
        // (elapsed-since-start) is that much behind the true track position — offset the baseline.
        baselineSeconds = incomingStartOffset
        position = baselineSeconds + currentDeck.elapsed
        currentPitchShiftSemitones = incomingPitchShiftSemitones
        isTransitioning = false
        transitionProgress = 0
        persistState()
        notifyUpcoming()
    }

    /// Cancels an in-flight transition, discarding the incoming deck. `currentDeck`/`currentIndex`
    /// remain the outgoing track; callers then restart on a chosen index.
    private func cancelTransition() {
        guard isTransitioning else { return }
        idleDeck.stop()
        idleDeck.volume = 1
        idleDeck.vocalsGain = 1
        idleDeck.bassGainDB = 0
        currentDeck.volume = 1
        currentDeck.vocalsGain = 1
        currentDeck.bassGainDB = 0
        isTransitioning = false
        transitionProgress = 0
    }

    private func hardAdvance(toIndex index: Int) {
        // Auto-advance (blend off / too short to blend): a natural completion, like
        // finishTransition — earn a skip back and record the history step.
        skipsRemaining = min(Player.maxSkips, skipsRemaining + 1)
        pushHistory(currentTrack)
        currentIndex = index
        startCurrentFresh()
        persistState()
    }

    private func stopPlayback() {
        currentDeck.pause()
        isPlaying = false
        stopTimer()
        persistState()
    }
}
