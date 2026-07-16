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
    public func prepare(tracks: [Track], startAt index: Int) {
        cancelTransition()
        queue = tracks
        currentIndex = max(0, min(index, tracks.count - 1))
        guard let track = currentTrack else { return }
        idleDeck.stop()
        currentDeck.stop()
        currentDeck.load(track)
        applyLoudness(to: currentDeck)
        currentPitchShiftSemitones = 0
        baselineSeconds = 0
        position = 0
        isPlaying = false
        persistState()
        notifyUpcoming()
    }

    /// Rebuilds the previous session from persisted state (missing tracks dropped), leaving the
    /// current track loaded and paused at its saved position.
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

        // Seek to the saved spot (real files only; the synth loop is position-agnostic).
        let target = max(0, min(state.positionSeconds, duration > 0 ? duration : state.positionSeconds))
        if target > 0, currentDeck.seekRealFile(to: target) {
            baselineSeconds = target
            position = target
        }
        persistState()
    }

    public func togglePlayPause() {
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

    public func next() {
        guard !queue.isEmpty, skipsRemaining > 0 else { return }
        skipsRemaining -= 1
        cancelTransition()
        pushHistory(currentTrack)
        currentIndex = (currentIndex + 1) % queue.count
        startCurrentFresh()
        persistState()
    }

    public func previous() {
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
        // Stepping back a track refunds a forward skip (capped) — undoing a skip shouldn't
        // leave the budget spent. Restart-current (above) deliberately doesn't refund.
        skipsRemaining = min(Player.maxSkips, skipsRemaining + 1)
        startCurrentFresh()
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

    public func seek(to seconds: TimeInterval) {
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
        currentDeck.pause()
        isPlaying = false
        stopTimer()
        persistState()
    }
}
