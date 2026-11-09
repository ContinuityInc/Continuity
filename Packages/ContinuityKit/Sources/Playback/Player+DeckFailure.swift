import AVFoundation
import Domain
import Observation
import ContinuityCore
import os

extension Player {
    // MARK: Deck start failures

    /// How many automatic retries a refused deck start gets before the transport stays paused
    /// and waits for the user (or a configuration-change recovery) to try again.
    static let maxDeckStartRetries = 2

    /// Starts the current deck and reports whether audio is actually running.
    ///
    /// `Deck.play()` returns false when AVFAudio refused the call — the engine stopped between
    /// the caller's `isRunning` check and the node call, or a stale schedule was about to be
    /// played. Before the shim those were process-ending exceptions; now they are this method's
    /// `false` branch, which is handled exactly like an engine stop: stage the position, pause,
    /// and schedule one deferred recovery through the first-play funnel.
    ///
    /// Callers must only set `isPlaying = true` / start the timer when this returns true.
    @discardableResult
    func startCurrentDeck(context: StaticString) -> Bool {
        guard let audio else { return false }
        if !audio.current.needsRescheduleAfterEngineStart, audio.current.play() {
            return true
        }
        handleDeckStartFailure(context: context)
        return false
    }

    /// Converts a refused start into a clean paused state at the current position.
    func handleDeckStartFailure(context: StaticString) {
        let label = String(describing: context)
        Logger.audio.error("deck refused to start (\(label, privacy: .public)) — staging \(self.position, privacy: .public)s and pausing")
        let resume = position
        cancelTransition()          // the idle deck's schedule is as suspect as the current one's
        audio?.current.stop()       // guarded; drops the schedule so the retry reloads from scratch
        pendingSeekSeconds = resume.isFinite && resume > 0 ? resume : nil
        isPlaying = false
        stopTimer()
        persistState()              // lock screen shows paused, position preserved
        scheduleDeckStartRetry()
    }

    /// One deferred retry per failure, bounded per track so a persistently dead engine can't
    /// loop. Uses the interruption-resume flag so an explicit user pause in the meantime
    /// (`togglePlayPause` clears it) cancels the retry.
    private func scheduleDeckStartRetry() {
        guard deckStartFailures < Player.maxDeckStartRetries else {
            Logger.audio.error("deck start retries exhausted — staying paused")
            return
        }
        deckStartFailures += 1
        resumeAfterInterruption = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.resumeAfterInterruption, !self.isPlaying,
                      self.currentTrack != nil, self.audio != nil else { return }
                self.resumeAfterInterruption = false
                Logger.audio.info("retrying deck start after refusal (attempt \(self.deckStartFailures, privacy: .public))")
                // Same funnel as first play after launch: rebuilds the schedule and applies
                // the staged seek, so the retry resumes where the refusal happened.
                guard self.ensureCurrentLoaded(), self.startCurrentDeck(context: "deck start retry") else { return }
                self.isPlaying = true
                self.startTimer()
                self.persistState()
            }
        }
    }
}
