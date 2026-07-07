import AVFoundation
import Observation
import ContinuityCore

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
    /// Seconds into the current track (drives the scrubber + clock).
    var position: TimeInterval = 0
    /// User-configurable crossfade settings (edited by `TransitionSettingsView`).
    var transitionSettings = TransitionSettings.default

    var currentTrack: Track? { queue.indices.contains(currentIndex) ? queue[currentIndex] : nil }
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

    init() {
        synthFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        deckA = Deck(engine: engine, mainMixer: engine.mainMixerNode, synthFormat: synthFormat)
        deckB = Deck(engine: engine, mainMixer: engine.mainMixerNode, synthFormat: synthFormat)
        currentDeck = deckA
        configureSession()
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    // MARK: Transport

    func play(tracks: [Track], startAt index: Int) {
        cancelTransition()
        queue = tracks
        currentIndex = max(0, min(index, tracks.count - 1))
        startCurrentFresh()
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
    }

    func next() {
        guard !queue.isEmpty else { return }
        cancelTransition()
        currentIndex = (currentIndex + 1) % queue.count
        startCurrentFresh()
    }

    func previous() {
        guard !queue.isEmpty else { return }
        cancelTransition()
        // Restart the current track if we're more than 3s in; otherwise go back one.
        if position > 3 {
            startCurrentFresh()
            return
        }
        currentIndex = (currentIndex - 1 + queue.count) % queue.count
        startCurrentFresh()
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
        currentDeck.load(track)
        baselineSeconds = 0
        position = 0
        currentDeck.play()
        isPlaying = true
        startTimer()
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

    private func tick() {
        guard isPlaying else { return }
        let elapsed = baselineSeconds + currentDeck.elapsed
        position = elapsed
        let dur = duration
        let plan = TransitionPlan(curve: transitionSettings.curve, duration: transitionSettings.durationSeconds)

        if isTransitioning {
            // Drive the blend off the INCOMING deck's clock — it keeps advancing even after the
            // outgoing file drains, so the transition can never get stuck half-faded.
            let incomingElapsed = idleDeck.elapsed
            let gains = plan.gains(position: incomingElapsed, startPosition: 0)
            currentDeck.volume = Float(gains.outgoing)
            idleDeck.volume = Float(gains.incoming)
            let progress = plan.progress(position: incomingElapsed, startPosition: 0)
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
        currentDeck = incoming
        currentIndex = transitionTargetIndex
        // The incoming was seeked `incomingStartOffset` in for beat alignment, so its deck clock
        // (elapsed-since-start) is that much behind the true track position — offset the baseline.
        baselineSeconds = incomingStartOffset
        position = baselineSeconds + currentDeck.elapsed
        isTransitioning = false
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
    }

    private func hardAdvance(toIndex index: Int) {
        currentIndex = index
        startCurrentFresh()
    }

    private func stopPlayback() {
        currentDeck.pause()
        isPlaying = false
        stopTimer()
    }
}
