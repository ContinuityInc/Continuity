import AVFoundation
import Domain
import Observation
import ContinuityCore
import os

extension Player {
    /// Starts the incoming track on the idle deck at zero gain; `tick()` then ramps the blend.
    func beginTransition(toIndex index: Int, outgoingPosition: Double) {
        guard queue.indices.contains(index) else { return }
        let incoming = idleDeck
        incoming.load(queue[index])
        applyLoudness(to: incoming)
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
    func applyVocalHandling(progress: Double) {
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
    func applyBassSwap(progress: Double) {
        idleDeck.bassGainDB = bassSwapCutDB * Float(max(0, 1 - progress / 0.6))
    }

    /// Completes the crossfade: stop the outgoing deck, promote the incoming deck to current.
    func finishTransition() {
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
    func cancelTransition() {
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
}
