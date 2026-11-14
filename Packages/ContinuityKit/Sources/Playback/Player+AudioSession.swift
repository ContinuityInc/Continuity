import AVFoundation
import Domain
import Observation
import ContinuityCore
import os

extension Player {
    // MARK: Audio-environment resilience

    /// The system stops the engine on interruptions (calls, Siri), route changes (headphones,
    /// output-device switches), and configuration resets. Untreated, the next deck call throws an
    /// ObjC exception — the classic "transient" crash. These observers turn those events into a
    /// clean pause + reschedule-and-resume instead.
    ///
    /// Registered by `ensureAudioStack()` — the handlers act on the engine, so pre-audio there is
    /// nothing to observe (and nothing may fire).
    func observeAudioEnvironment(engine: AVAudioEngine) {
        let center = NotificationCenter.default
        // A rebuild (media-services reset) must not stack a second set of session-level handlers.
        audioEnvironmentObservers.forEach { center.removeObserver($0) }
        audioEnvironmentObservers.removeAll()

        audioEnvironmentObservers.append(center.addObserver(
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
                    // Defer: interruption-end handlers can nest under session activation, and
                    // a sync recoverPlayback → ensureRunning → start() can re-post this.
                    self?.scheduleRecoverPlayback(force: false)
                default:
                    break
                }
            }
        })

        audioEnvironmentObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            MainActor.assumeIsolated {
                // Headphones unplugged / output vanished: pause (standard platform UX). Other
                // route changes are handled by the configuration-change recovery below.
                // No auto-resume: the platform convention after an unplug is to stay paused,
                // and a later interruption's .shouldResume must not un-pause this.
                if reason == .oldDeviceUnavailable {
                    Logger.audio.info("audio route lost — pausing")
                    self?.pauseForEnvironment(allowAutoResume: false)
                }
            }
        })

        audioEnvironmentObservers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // The engine stopped itself to apply a new configuration (sample rate/route).
                // Node schedules are gone; reschedule from the current position and keep going.
                guard let self, self.isPlaying else { return }
                // Spurious changes happen with the engine still rendering — notably the
                // Taptic Engine (context-menu long-press haptic) sharing the audio hardware.
                // Recovery stops + reschedules both stem players (an audible ~1s dropout),
                // so only do it when the engine actually stopped. The stop can land just AFTER
                // this callback (Live Activity / Dynamic Island updates exercise that race), so
                // recheck once after the system has settled instead of trusting one snapshot.
                guard !engine.isRunning else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, self.isPlaying,
                                  let currentEngine = self.audio?.engine,
                                  currentEngine === engine,
                                  !engine.isRunning else { return }
                            Logger.audio.error("engine stopped after configuration callback — recovering")
                            self.scheduleRecoverPlayback(force: true)
                        }
                    }
                    return
                }
                Logger.audio.info("engine configuration change — recovering playback")
                // Always async: NotificationCenter delivers main-queue observers *synchronously*
                // when the poster is on main, and `engine.start()` inside recovery is a known
                // poster. Sync re-entry was the residual "transient" crash after the AVFAudio shim.
                self.scheduleRecoverPlayback(force: true)
            }
        })

        audioEnvironmentObservers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleMediaServicesReset()
            }
        })
    }

    /// The media server crashed and restarted: every live AVAudio object (engine, nodes, the
    /// session's state) is now invalid, and no amount of engine.start() retries can revive them.
    /// Discard the stack so the next audio need rebuilds it from scratch (fresh session
    /// activation + observers), and resume in place if we were playing.
    private func handleMediaServicesReset() {
        Logger.audio.error("media services were reset — discarding audio stack")
        let wasPlaying = isPlaying
        let resumePosition = position
        // Don't touch the dead engine/decks — even stop() can throw on orphaned nodes.
        clearTransitionState()
        isPlaying = false
        stopTimer()
        // Detach the dead stack from the player, but do NOT let it deallocate here.
        // `-[AVAudioEngine dealloc]` tears the engine down with a synchronous hop onto its
        // internal queue; AVFAudio documents that doing so from inside a notification
        // callout can deadlock, and in the field it shows up as a `__DISPATCH_WAIT_FOR_QUEUE__`
        // trap under `-[AVAudioEngine dealloc]` — a crash with no app frame in it. Keep the
        // orphan alive past this callout and let it go on a later main turn.
        let orphaned = audio
        audio = nil
        resumeAfterInterruption = false
        if resumePosition > 0 { pendingSeekSeconds = resumePosition }
        persistState()       // lock screen shows paused at the preserved position
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withExtendedLifetime(orphaned) {}
        }
        guard wasPlaying else { return }
        // Rebuild on the next main turn, outside the notification callout: the fresh engine's
        // first `mainMixerNode` access is a CoreAudio RPC against a server that has only just
        // come back, and nothing here must run with the dead stack still mid-teardown.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isPlaying, self.audio == nil, self.currentTrack != nil else { return }
                // ensureCurrentLoaded() builds the fresh stack, reloads the current track, and
                // applies the staged seek — the same funnel as first play after launch.
                guard self.ensureCurrentLoaded(), self.startCurrentDeck(context: "mediaServicesReset") else { return }
                self.isPlaying = true
                self.startTimer()
                self.persistState()
            }
        }
    }

    /// Clean pause in response to the environment (vs. the user's pause button): remembers that
    /// playback should resume if the system later allows it (`allowAutoResume` — headphone
    /// unplugs pause without ever auto-resuming).
    private func pauseForEnvironment(allowAutoResume: Bool = true) {
        guard isPlaying else { return }
        resumeAfterInterruption = allowAutoResume
        cancelTransition()     // blend state won't survive an engine stop; finish cleanly
        audio?.current.pause() // engine-state-guarded; no-ops if the engine is already down
        isPlaying = false
        stopTimer()
        persistState()       // lock screen should show paused immediately
    }

    /// Posts recovery onto a later main-queue turn so a notification delivered synchronously
    /// from inside `engine.start()` / session activation cannot re-enter `recoverPlayback`.
    ///
    /// Requests are coalesced: while one recovery is pending, further requests fold into it
    /// (a forced request upgrades a pending soft one) instead of queueing their own, and
    /// attempts are spaced at least `recoveryMinimumIntervalSeconds` apart. Around a route
    /// change this is called from the engine notification, its 50 ms recheck, the
    /// interruption-ended handler and every 20 Hz tick that finds the engine stopped —
    /// before, each of those ran a full recovery of its own.
    func scheduleRecoverPlayback(force: Bool) {
        guard let delay = recoveryCoalescer.request(force: force, now: Player.monotonicNow()) else {
            return   // folded into the pending recovery
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let force = self.recoveryCoalescer.fire()
                self.recoverPlayback(force: force)
            }
        }
    }

    /// Monotonic seconds for recovery spacing — never wall-clock, which jumps.
    static func monotonicNow() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// Restarts the engine and reschedules the current track at the current position. `force`
    /// recovers even without a preceding `pauseForEnvironment` (configuration changes stop the
    /// engine without an interruption notification).
    func recoverPlayback(force: Bool = false) {
        // Nested entry (sync notification from start(), or overlapping async schedules) must
        // not double-disconnect / double-schedule the decks — that is the residual crash class
        // after the AVFAudio exception shim: recovery itself becoming the exception source.
        guard !isRecoveringPlayback else {
            Logger.audio.info("recoverPlayback coalesced (already in flight)")
            return
        }
        guard force || resumeAfterInterruption else { return }
        isRecoveringPlayback = true
        defer { isRecoveringPlayback = false }
        resumeAfterInterruption = false
        // Observers only exist once the stack does, so `audio` is always live here.
        guard currentTrack != nil, let audio else { return }
        // A recovery that arrives after an earlier one (or a deck-start retry) already brought
        // the engine back and rescheduled the deck has nothing to do. Running it anyway means
        // disconnecting/reconnecting a playing node and rescheduling on a live engine — an
        // audible skip at best, and the kind of graph churn AVFAudio asserts on at worst.
        if PlaybackRecoveryCoalescer.isRecoveryRedundant(
            engineIsRunning: audio.engine.isRunning,
            deckNeedsReschedule: audio.current.needsRescheduleAfterEngineStart,
            deckHasTrack: audio.current.track != nil,
            isPlaying: isPlaying
        ) {
            Logger.audio.info("recoverPlayback skipped — engine already running and deck rescheduled")
            return
        }
        recoveryCoalescer.recordAttempt(now: Player.monotonicNow())
        let transitionWasInterrupted = isTransitioning
        // Rebuild player→mixer connections while the engine is still stopped. A route change
        // can leave the previous bus formats unconvertible for the new hardware rate; starting
        // first and reconnecting later is what raised
        // `IsFormatSampleRateAndChannelCountValid(outputHWFormat)` mid-recovery. Never do this
        // on a running engine: if another path restarted it since the request was made, the
        // bus formats it started with are the valid ones.
        if !audio.engine.isRunning {
            audio.deckA.reconnectAfterConfigurationChange()
            audio.deckB.reconnectAfterConfigurationChange()
        }
        guard ensureRunning() else {
            if transitionWasInterrupted {
                // The idle deck's schedule is no longer trustworthy. Clear the blend flags even
                // when CoreAudio cannot restart so a later play cannot resume that stale deck.
                clearTransitionState()
            }
            Logger.audio.error("engine restart failed during recovery")
            isPlaying = false
            stopTimer()
            return
        }
        if transitionWasInterrupted {
            // Configuration-change recovery bypasses pauseForEnvironment(), but an engine stop
            // invalidates both decks just the same. Drop the incoming deck before rescheduling
            // the outgoing one; otherwise pause/resume can call play() on its stale schedule.
            Logger.audio.info("engine stop interrupted transition — discarding incoming deck")
            cancelTransition()
        }
        // Engine stops invalidate node schedules — reschedule from where the clock stood.
        if audio.current.track == nil {
            // The deck-start failure funnel unloaded the deck and staged the position in
            // `pendingSeekSeconds`. Reload through the first-play funnel (which applies that
            // seek) rather than the synth-deck fallback below, which would restart from 0.
            guard ensureCurrentLoaded(), startCurrentDeck(context: "recoverPlayback(reload)") else { return }
            isPlaying = true
            startTimer()
        } else if audio.current.seekRealFile(to: position) {
            baselineSeconds = position
            // A refusal stages the position, pauses and persists through the failure funnel.
            guard startCurrentDeck(context: "recoverPlayback") else { return }
            isPlaying = true
            startTimer()
        } else if audio.current.hasRealFile {
            // The engine stopped again between ensureRunning() and the reschedule. Unload the
            // invalid schedule and stage this position so the next explicit play rebuilds it.
            Logger.audio.error("engine stopped again during playback reschedule")
            pendingSeekSeconds = position
            audio.current.stop()
            isPlaying = false
            stopTimer()
        } else {
            // Synth deck: the loop is position-agnostic; a fresh start is equivalent.
            startCurrentFresh()
        }
        persistState()       // lock screen should show playing again after recovery
    }

    func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        // Every system interruption stops the engine, and every engine stop is a chance to hit
        // the check-then-call window where an AVFAudio node call raises an uncatchable ObjC
        // exception. A media playback app is allowed to opt out of the incidental ones (system
        // alerts) — fewer interruptions is fewer chances. Best-effort: never worth failing
        // session setup over.
        try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
        try? session.setActive(true)
    }
}
