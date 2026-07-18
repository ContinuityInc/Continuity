import AVFoundation
import Domain
import Observation
import ContinuityCore
import os

extension Player {
    /// Starts the incoming track on the idle deck at zero gain; `tick()` then ramps the blend.
    func beginTransition(toIndex index: Int, outgoingPosition: Double) {
        guard queue.indices.contains(index) else { return }
        // Only reachable from tick() while playing, so the stack exists; funnel anyway.
        let audio = ensureAudioStack()
        let incoming = audio.idle
        incoming.load(queue[index])
        applyLoudness(to: incoming)
        incoming.volume = 0
        incoming.rate = 1
        incomingStartOffset = 0

        // Beatmatch: when both tracks have a detected tempo and the stretch is modest, retempo the
        // incoming deck to the outgoing track so they beat together through the blend. Otherwise
        // (synth samples, missing tempo, or too large a stretch) leave rate at 1 and fall back to
        // the plain equal-power crossfade.
        // Match against the outgoing track's EFFECTIVE tempo: it may itself be playing
        // rate-shifted from its own beatmatched entry (the rate persists for the whole track,
        // like the harmonic pitch shift below).
        var rate = 1.0
        incomingRate = 1
        if transitionSettings.beatmatchEnabled,
           let outBPM = audio.current.track?.bpm,
           let inBPM = queue[index].bpm,
           let matched = BeatMath.matchRate(incomingBPM: inBPM, outgoingBPM: outBPM * currentRate) {
            rate = matched
            incomingRate = matched
            incoming.rate = Float(matched)
        }

        // Beat-align: seek the incoming so one of its beats lands on an upcoming outgoing beat,
        // phase-locking the two grids through the blend (the "you won't notice" bit). Needs a beat
        // grid on both tracks; declines gracefully — and only when the seek lands — leaving the
        // incoming at its start otherwise.
        if transitionSettings.beatmatchEnabled,
           let outBeats = audio.current.track?.beatTimes, !outBeats.isEmpty,
           let offset = BeatMath.incomingStartOffset(
               outgoingPosition: outgoingPosition,
               outgoingBeats: outBeats,
               incomingBeats: queue[index].beatTimes,
               rate: rate,
               outgoingRate: currentRate
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
           let outKey = audio.current.track?.camelotCode.flatMap(Camelot.parse),
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
    func applyVocalHandling(progress: Double) {
        guard let audio else { return }
        switch transitionSettings.vocalMode {
        case .duck:
            // Outgoing vocals fade out over the first ~70% of the blend; incoming vocals ride in.
            audio.current.vocalsGain = Float(max(0, 1 - progress / 0.7))
        case .instrumentalOverlap:
            // Outgoing vocals out fast; incoming vocals only enter in the second half.
            audio.current.vocalsGain = Float(max(0, 1 - progress / 0.5))
            audio.idle.vocalsGain = Float(min(1, max(0, (progress - 0.5) / 0.5)))
        case .hardSwap:
            audio.current.vocalsGain = progress < 0.5 ? 1 : 0
            audio.idle.vocalsGain = progress < 0.5 ? 0 : 1
        }
    }

    /// Fades the incoming deck's low end in over the first ~60% of the blend, so the two basslines
    /// don't stack into low-end mud. Only called while `bassSwapEnabled`.
    func applyBassSwap(progress: Double) {
        audio?.idle.bassGainDB = bassSwapCutDB * Float(max(0, 1 - progress / 0.6))
    }

    /// Completes the crossfade: stop the outgoing deck, promote the incoming deck to current.
    func finishTransition() {
        guard let audio else { return }   // blends only exist post-build
        let outgoing = audio.current
        let incoming = audio.idle
        outgoing.stop()
        outgoing.volume = 1
        outgoing.vocalsGain = 1
        outgoing.bassGainDB = 0
        incoming.volume = 1
        incoming.vocalsGain = 1
        incoming.bassGainDB = 0
        // Natural end-of-track blend: earn one forward skip back (capped). A SKIP blend is a
        // spend, not a completion — no earn, or the budget would never deplete. Both record
        // the history step for unlimited previous-skips.
        if !transitionIsSkip {
            skipsRemaining = min(Player.maxSkips, skipsRemaining + 1)
        }
        pushHistory(currentTrack)
        audio.current = incoming
        currentIndex = transitionTargetIndex
        queueRefillAttempted = false   // deck promotion changes the current track sans startCurrentFresh
        // The incoming was seeked `incomingStartOffset` in for beat alignment, so its deck clock
        // (elapsed-since-start) is that much behind the true track position — offset the baseline.
        baselineSeconds = incomingStartOffset
        position = baselineSeconds + incoming.elapsed
        currentPitchShiftSemitones = incomingPitchShiftSemitones
        currentRate = incomingRate
        isTransitioning = false
        transitionProgress = 0
        activeTransitionDuration = nil
        transitionIsSkip = false
        persistState()
        notifyUpcoming()
    }

    /// Cancels an in-flight transition, discarding the incoming deck. The current deck and
    /// `currentIndex` remain the outgoing track; callers then restart on a chosen index.
    func cancelTransition() {
        guard isTransitioning else { return }
        if let audio {
            audio.idle.stop()
            audio.idle.volume = 1
            audio.idle.vocalsGain = 1
            audio.idle.bassGainDB = 0
            audio.current.volume = 1
            audio.current.vocalsGain = 1
            audio.current.bassGainDB = 0
        }
        isTransitioning = false
        transitionProgress = 0
        activeTransitionDuration = nil
        transitionIsSkip = false
    }
}
