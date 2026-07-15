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
    func observeAudioEnvironment() {
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

    func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }
}
