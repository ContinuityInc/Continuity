import Foundation

/// Decides *when* an audio-engine recovery may run, independently of AVFoundation.
///
/// Recovery (restart the engine, reconnect the decks, reschedule, play) is requested from
/// several places at once around a route or configuration change: the engine's own
/// configuration-change notification, a 50 ms recheck of a notification that looked spurious,
/// the interruption-ended handler, and the 20 Hz playback tick for every tick that finds the
/// engine stopped. Each request used to enqueue its own recovery, so after the first one had
/// restarted the engine the rest ran *again* on a live, playing graph — disconnecting and
/// reconnecting player nodes and rescheduling files on a running engine, several times in a
/// row, during exactly the route churn AVFAudio is least stable in. A flapping route could
/// keep that going at tick rate.
///
/// This type folds all requests into one pending recovery (a forced request upgrades a pending
/// soft one), and spaces attempts by `minimumInterval` so a flap cannot drive start/stop cycles
/// faster than CoreAudio can settle. The *content* of a recovery stays in the Playback module;
/// only the scheduling policy lives here, where it can run on Linux CI.
public struct PlaybackRecoveryCoalescer: Equatable, Sendable {
    /// Minimum spacing between two recovery attempts, in seconds.
    public let minimumInterval: TimeInterval
    /// True while a recovery is scheduled but has not fired yet.
    public private(set) var isScheduled = false
    /// Whether the pending recovery should run as a forced recovery.
    public private(set) var pendingForce = false
    /// Monotonic time of the last recovery that actually ran its body.
    public private(set) var lastAttempt: TimeInterval?

    public init(minimumInterval: TimeInterval = 0.25) {
        self.minimumInterval = minimumInterval.isFinite && minimumInterval > 0 ? minimumInterval : 0
    }

    /// Registers a recovery request made at monotonic time `now`.
    ///
    /// Returns the delay after which the caller must call `fire()` and run the recovery, or
    /// `nil` when a recovery is already scheduled — the request has been folded into it
    /// (upgrading it to forced when `force` is set) and the caller must not schedule another.
    public mutating func request(force: Bool, now: TimeInterval) -> TimeInterval? {
        pendingForce = pendingForce || force
        guard !isScheduled else { return nil }
        isScheduled = true
        guard let lastAttempt, now.isFinite, lastAttempt.isFinite else { return 0 }
        let sinceLast = now - lastAttempt
        // A clock that went backwards (or a corrupt reading) is treated as "long ago".
        guard sinceLast >= 0, sinceLast < minimumInterval else { return 0 }
        return minimumInterval - sinceLast
    }

    /// Called when the scheduled delay elapses. Clears the pending state and returns the force
    /// flag the recovery should run with. Requests arriving after this call start a new cycle.
    public mutating func fire() -> Bool {
        let force = pendingForce
        isScheduled = false
        pendingForce = false
        return force
    }

    /// Records that a recovery body actually ran at monotonic time `now`, so the next request
    /// is spaced from it. Recoveries that bail out early (nothing to recover) should not call
    /// this — they did not touch the engine.
    public mutating func recordAttempt(now: TimeInterval) {
        guard now.isFinite else { return }
        lastAttempt = now
    }

    /// Whether a recovery is needed at all, given the engine's and the deck's current state.
    ///
    /// A recovery that arrives after another one already restarted the engine and rescheduled
    /// the current deck has nothing left to do; running it anyway means graph surgery on a
    /// live engine. Only the interruption-resume case (`isPlaying == false` with the engine
    /// up) still needs to run, because it has to start the deck.
    public static func isRecoveryRedundant(
        engineIsRunning: Bool,
        deckNeedsReschedule: Bool,
        deckHasTrack: Bool,
        isPlaying: Bool
    ) -> Bool {
        engineIsRunning && !deckNeedsReschedule && deckHasTrack && isPlaying
    }

    /// Whether a fired recovery request should run its body, given transport intent *now*.
    ///
    /// Forced requests are scheduled while `isPlaying` is still true (config-change observer,
    /// tick). Soft requests carry `resumeAfterInterruption` from an environment pause. Between
    /// `request` and `fire` the user (or a headphone-unplug pause that clears auto-resume) can
    /// take control — a forced recovery must not restart audio against that pause. A pending
    /// soft resume (interruption end, deck-start retry) still runs even while paused.
    public static func shouldRunRecovery(
        force: Bool,
        isPlaying: Bool,
        resumeAfterInterruption: Bool
    ) -> Bool {
        (force && isPlaying) || resumeAfterInterruption
    }
}
