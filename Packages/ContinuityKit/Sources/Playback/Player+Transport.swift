import AVFoundation
import Domain
import Observation
import ContinuityCore
import os

extension Player {
    // MARK: Transport

    public func play(tracks: [Track], startAt index: Int) {
        cancelTransition()
        pushHistory(currentTrack)
        queue = tracks
        currentIndex = max(0, min(index, tracks.count - 1))
        startCurrentFresh()
        persistState()
    }

    /// Like `play(tracks:startAt:)` but left paused at the start — used to stage the session's
    /// first track on the Now Playing screen without blasting audio at launch.
    ///
    /// Metadata-only: no deck load, no engine build (see `ensureAudioStack()`) — staging must
    /// survive a wedged CoreAudio server. The track loads on the first real play.
    public func prepare(tracks: [Track], startAt index: Int) {
        cancelTransition()
        queue = tracks
        currentIndex = max(0, min(index, tracks.count - 1))
        guard currentTrack != nil else { return }
        // Re-prepare mid-session: silence + unload existing decks, but never build them for this.
        if let audio {
            audio.idle.stop()
            audio.current.stop()
        }
        currentPitchShiftSemitones = 0
        currentRate = 1
        cancelPitchSettle()   // restaging supersedes any in-flight post-transition settle
        queueRefillAttempted = false   // restaged track earns a fresh exhaustion refill
        baselineSeconds = 0
        position = 0
        pendingSeekSeconds = nil
        isPlaying = false
        persistState()
        // Do NOT call notifyUpcoming() here. prepare/restore run at cold launch while paused;
        // kicking stem separation then loads the ~158 MB HT-Demucs ORT session and has jetsammed
        // real devices at the ~3.4 GB per-process limit (SIGKILL) before the user ever hits play.
        // Stems start from ensureCurrentLoaded / startCurrentFresh on first real audio.
    }

    /// Rebuilds the previous session from persisted state (missing tracks dropped), leaving the
    /// current track staged paused at its saved position (the seek itself is deferred until
    /// audio first materializes).
    public func restore(_ state: PersistedPlaybackState, resolving tracksByID: [UUID: Track]) {
        let tracks = state.queueTrackIDs.compactMap { tracksByID[$0] }
        guard !tracks.isEmpty else { return }
        skipsRemaining = max(0, min(Player.maxSkips, state.skipsRemaining))
        historyIDs = state.historyTrackIDs.filter { tracksByID[$0] != nil }

        // Map the saved index through any dropped tracks by following the saved current track ID.
        let savedCurrentID = state.queueTrackIDs.indices.contains(state.currentIndex)
            ? state.queueTrackIDs[state.currentIndex] : nil
        let index = savedCurrentID.flatMap { id in tracks.firstIndex { $0.id == id } } ?? 0

        prepare(tracks: tracks, startAt: index)

        // Stage the saved spot; ensureCurrentLoaded() applies it when audio first materializes.
        let target = max(0, min(state.positionSeconds, duration > 0 ? duration : state.positionSeconds))
        if target > 0 {
            baselineSeconds = target
            position = target
            pendingSeekSeconds = target
        }
        persistState()
    }

    public func togglePlayPause() {
        guard currentTrack != nil else { return }
        // The user has taken control: a pending "resume when the interruption ends" must not
        // override an explicit pause (or double-fire after an explicit resume).
        resumeAfterInterruption = false
        if isPlaying {
            // isPlaying implies the stack exists; guard-let keeps the pause structurally safe.
            if let audio {
                audio.current.pause()
                if isTransitioning { audio.idle.pause() }
            }
            isPlaying = false
            stopTimer()
        } else {
            // First real audio need: build the stack, load the staged track, apply pending seek.
            guard ensureCurrentLoaded(), let audio else { isPlaying = false; return }
            // If the queue had ended, replay from the start instead of resuming into what's left.
            // Compare against the same trimmed end tick() stops at — with silence trimming the
            // playhead parks before the file's full duration, and resuming there would just play
            // trailing silence until the next tick stops it again (a dead play button).
            if !isTransitioning, effectiveEndSeconds > 0, position >= effectiveEndSeconds - 0.05 {
                startCurrentFresh()
            } else {
                audio.current.play()
                if isTransitioning { audio.idle.play() }
                isPlaying = true
                startTimer()
            }
        }
        persistState()
    }

    public func next() {
        guard !queue.isEmpty, skipsRemaining > 0 else { return }
        // A second press during an explicit skip would only restart the same incoming track,
        // spending another skip without advancing farther.
        guard !isUserInitiatedSkipTransition else { return }
        // If an automatic blend is already underway, restart it as a five-second user skip.
        cancelTransition()
        skipsRemaining -= 1
        pushHistory(currentTrack)
        let targetIndex = (currentIndex + 1) % queue.count

        // Skipping from a paused/staged session still needs the outgoing deck materialized so
        // there is audio to fade away. If CoreAudio cannot start, preserve the old hard-advance
        // behavior rather than leaving the transport on the track the user skipped.
        guard ensureCurrentLoaded(), let audio else {
            currentIndex = targetIndex
            startCurrentFresh()
            persistState()
            return
        }
        if !isPlaying {
            audio.current.play()
            isPlaying = true
            startTimer()
        }
        resumeAfterInterruption = false
        // Clamp the fade to the audio actually LEFT on the outgoing track: a 5 s blend with
        // only 4 s of outgoing audio ends in the file draining at ~30% gain — an audible hard
        // cut instead of a fade (short tracks / hot endings). Under a second remaining isn't
        // enough to read as a blend at all — hard-advance instead.
        let remaining = effectiveEndSeconds - position
        guard remaining > 1 else {
            currentIndex = targetIndex
            startCurrentFresh()
            persistState()
            return
        }
        beginTransition(
            toIndex: targetIndex,
            outgoingPosition: position,
            duration: min(Player.skipTransitionDurationSeconds, remaining),
            isUserInitiatedSkip: true
        )
        persistState()
    }

    public func previous() {
        guard !queue.isEmpty else { return }
        // A second press during an explicit skip would cancel the in-flight blend and walk the
        // history a second time — dropping the entry it already consumed and double-refunding the
        // skip. Ignore it until the blend lands, mirroring next().
        guard !isUserInitiatedSkipTransition else { return }
        // If an automatic blend is already underway, restart it as a user skip-back.
        cancelTransition()
        // Restart the current track if we're more than 3s in; otherwise step back through the
        // play history (unlimited), falling back to the previous queue slot when history is empty
        // or refers to tracks no longer in the queue.
        if position > 3 {
            startCurrentFresh()
            return
        }
        // Walk back to the most recent history entry still in the queue, consuming ONLY that
        // entry. Non-matching entries (older playlists/queues) must survive the walk — popping
        // them would let one previous() press after a playlist switch destroy the entire
        // persistent history, which also feeds the queue-exhausted refill loop.
        var backIndex: Int?
        if let historyIdx = historyIDs.lastIndex(where: { id in queue.contains { $0.id == id } }) {
            backIndex = queue.firstIndex { $0.id == historyIDs[historyIdx] }
            historyIDs.remove(at: historyIdx)
        }
        let targetIndex = backIndex ?? (currentIndex - 1 + queue.count) % queue.count
        // Stepping back a track refunds a forward skip (capped) — undoing a skip shouldn't
        // leave the budget spent. Restart-current (above) deliberately doesn't refund. A skip
        // blend spends nothing on completion (finishTransition skips the refund for user skips),
        // so this single refund holds whether we blend or hard-cut below.
        skipsRemaining = min(Player.maxSkips, skipsRemaining + 1)

        // No distinct earlier track to blend into (single-track queue, or the most recent history
        // entry is the current track) — a self-blend would just echo the same audio, so restart
        // instead, exactly as the >3s branch does.
        guard targetIndex != currentIndex else {
            startCurrentFresh()
            persistState()
            return
        }

        // Blend back into the previous track exactly like next() blends forward: materialize the
        // outgoing deck so there is audio to fade, then hand off on the idle deck. Skipping from a
        // paused/staged session still needs the outgoing deck so there is something to fade away;
        // if CoreAudio cannot start, hard-advance to the target rather than stranding the transport.
        guard ensureCurrentLoaded(), let audio else {
            currentIndex = targetIndex
            startCurrentFresh()
            persistState()
            return
        }
        if !isPlaying {
            audio.current.play()
            isPlaying = true
            startTimer()
        }
        resumeAfterInterruption = false
        // Clamp the fade to the audio actually LEFT on the outgoing track (short tracks / hot
        // endings), and hard-advance when under a second remains — too little to read as a blend.
        let remaining = effectiveEndSeconds - position
        guard remaining > 1 else {
            currentIndex = targetIndex
            startCurrentFresh()
            persistState()
            return
        }
        beginTransition(
            toIndex: targetIndex,
            outgoingPosition: position,
            duration: min(Player.skipTransitionDurationSeconds, remaining),
            isUserInitiatedSkip: true
        )
        persistState()
    }

    /// Removes deleted tracks from the live queue BEFORE their SwiftData models are destroyed —
    /// a deck or queue reference to a deleted `@Model` would crash on next access. Handles every
    /// case: blend target deleted (cancel the blend), current track deleted (jump to the next
    /// surviving track, preserving play/pause state), and plain queue shrinkage (fix indices).
    public func handleDeleted(trackIDs: Set<UUID>) {
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
                // Guard, don't build: deleting tracks must never construct the engine.
                audio?.current.stop()
                audio?.idle.stop()
                currentIndex = 0
                position = 0
                pendingSeekSeconds = nil
                isPlaying = false
                stopTimer()
            } else {
                currentIndex = min(survivorsBeforeCurrent, queue.count - 1)
                if let audio {
                    startCurrentFresh()
                    if !wasPlaying {
                        audio.current.pause()
                        isPlaying = false
                        stopTimer()
                    }
                } else {
                    // Pre-audio: restage the survivor metadata-only; it loads on first play.
                    baselineSeconds = 0
                    position = 0
                    pendingSeekSeconds = nil
                    notifyUpcoming()   // startCurrentFresh would have; stems prep needs the new neighborhood
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

    public func seek(to seconds: TimeInterval) {
        let clamped = max(0, min(seconds, duration))
        cancelTransition() // re-evaluate the transition window from the new position
        // Paused pre-audio scrub: metadata-only — move the clock and stage the seek for when
        // audio first materializes. (isPlaying is impossible without a loaded deck.)
        guard let audio, audio.current.track?.id == currentTrack?.id, currentTrack != nil else {
            baselineSeconds = clamped
            position = clamped
            pendingSeekSeconds = clamped
            persistState()
            return
        }
        pendingSeekSeconds = nil   // a live deck seek supersedes any staged one
        guard audio.engine.isRunning else {
            // A system event invalidated the schedule before the seek reached the deck. Leave the
            // requested position staged for a clean reload instead of touching stopped nodes.
            pendingSeekSeconds = clamped
            audio.current.stop()
            baselineSeconds = clamped
            position = clamped
            isPlaying = false
            stopTimer()
            persistState()
            return
        }
        if audio.current.seekRealFile(to: clamped) {
            baselineSeconds = clamped
            position = clamped
            if isPlaying {
                guard audio.engine.isRunning else {
                    pendingSeekSeconds = clamped
                    audio.current.stop()
                    isPlaying = false
                    stopTimer()
                    persistState()
                    return
                }
                audio.current.play()
            }
        } else if audio.current.hasRealFile {
            // The engine stopped between the initial check and segment scheduling.
            pendingSeekSeconds = clamped
            baselineSeconds = clamped
            position = clamped
            audio.current.stop()
            isPlaying = false
            stopTimer()
        } else {
            // Synth deck: looped audio is identical at any offset, so just move the clock.
            baselineSeconds = clamped - audio.current.elapsed
            position = clamped
        }
        persistState()   // saved position + lock-screen elapsed both move with the scrub
    }

    func hardAdvance(toIndex index: Int) {
        // Auto-advance (blend off / too short to blend): a natural completion, like
        // finishTransition — earn a skip back and record the history step.
        skipsRemaining = min(Player.maxSkips, skipsRemaining + 1)
        pushHistory(currentTrack)
        currentIndex = index
        startCurrentFresh()
        persistState()
    }

    func stopPlayback() {
        audio?.current.pause()   // only called mid-play, but never worth building a stack to pause
        isPlaying = false
        stopTimer()
        persistState()
    }
}
