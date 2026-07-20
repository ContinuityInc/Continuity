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
                    self?.recoverPlayback()
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
                // so only do it when the engine actually stopped.
                guard !engine.isRunning else {
                    Logger.audio.info("engine configuration change — engine still running, skipping recovery")
                    return
                }
                Logger.audio.info("engine configuration change — recovering playback")
                self.recoverPlayback(force: true)
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
        isTransitioning = false
        transitionProgress = 0
        isPlaying = false
        stopTimer()
        audio = nil
        resumeAfterInterruption = false
        if resumePosition > 0 { pendingSeekSeconds = resumePosition }
        if wasPlaying {
            // ensureCurrentLoaded() builds the fresh stack, reloads the current track, and
            // applies the staged seek — the same funnel as first play after launch.
            if ensureCurrentLoaded(), let audio {
                audio.current.play()
                isPlaying = true
                startTimer()
            }
        }
        persistState()
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

    /// Restarts the engine and reschedules the current track at the current position. `force`
    /// recovers even without a preceding `pauseForEnvironment` (configuration changes stop the
    /// engine without an interruption notification).
    private func recoverPlayback(force: Bool = false) {
        guard force || resumeAfterInterruption else { return }
        resumeAfterInterruption = false
        // Observers only exist once the stack does, so `audio` is always live here.
        guard currentTrack != nil, let audio else { return }
        guard ensureRunning() else {
            Logger.audio.error("engine restart failed during recovery")
            isPlaying = false
            stopTimer()
            return
        }
        // Engine stops invalidate node schedules — reschedule from where the clock stood.
        if audio.current.seekRealFile(to: position) {
            baselineSeconds = position
            audio.current.play()
            isPlaying = true
            startTimer()
        } else {
            // Synth deck: the loop is position-agnostic; a fresh start is equivalent.
            startCurrentFresh()
        }
        persistState()       // lock screen should show playing again after recovery
    }

    func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }
}
