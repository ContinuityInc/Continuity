import AVFoundation
import AVFAudioShim
import os

/// The only place in Playback allowed to call AVFAudio node methods directly
/// (`Scripts/check-avfaudio-boundary.sh` enforces this in CI).
///
/// AVFAudio reports precondition failures as Objective-C exceptions — `play()` on an engine
/// that a route change just stopped (`_engine->IsRunning()`), `play(at:)` with a start time
/// already in the past, `scheduleSegment` with a bad range, `connect` with a format the graph
/// can't convert, `start()` when the output hardware format is momentarily invalid. Swift has
/// no handler for those, so the runtime aborts: that is the SIGABRT behind every "transient"
/// crash that clustered around interruptions, AirPods, car stereos and Siri. The
/// `engine.isRunning` checks around each call shrink the window but cannot close it — the
/// engine can stop between the check and the call.
///
/// Every wrapper below runs its call inside `AVFAudioShimTry` (ObjC `@try/@catch`) and
/// returns whether it completed. A failure is logged with the exception's reason — the first
/// time the app has been able to say *which* AVFAudio precondition fired in the field — and
/// counted for the diagnostics report. Callers treat `false` the way they already treat a
/// stopped engine: stage the position, pause, let recovery reschedule.
public enum AVFAudioGuard {
    /// In-process count of AVFAudio exceptions caught — the number of times this process
    /// *would have died* before the shim. Read by the app's diagnostics report; never reset.
    @MainActor public private(set) static var caughtExceptionCount = 0
    /// Most recent caught exception, for the diagnostics report.
    @MainActor public private(set) static var lastCaughtDescription: String?

    @MainActor
    @discardableResult
    static func attempt(_ what: StaticString, _ body: () -> Void) -> Bool {
        var error: NSError?
        if AVFAudioShimTry(body, &error) { return true }
        caughtExceptionCount += 1
        let label = String(describing: what)
        let description = error?.localizedDescription ?? "unknown exception"
        lastCaughtDescription = "\(label): \(description)"
        Logger.audio.fault("AVFAudio exception caught in \(label, privacy: .public): \(description, privacy: .public)")
        return false
    }
}

// MARK: - AVAudioPlayerNode

extension AVAudioPlayerNode {
    @MainActor @discardableResult
    func guardedPlay() -> Bool {
        AVFAudioGuard.attempt("play") { self.play() }
    }

    @MainActor @discardableResult
    func guardedPlay(at when: AVAudioTime) -> Bool {
        AVFAudioGuard.attempt("play(at:)") { self.play(at: when) }
    }

    @MainActor @discardableResult
    func guardedPause() -> Bool {
        AVFAudioGuard.attempt("pause") { self.pause() }
    }

    @MainActor @discardableResult
    func guardedStop() -> Bool {
        AVFAudioGuard.attempt("stop") { self.stop() }
    }

    @MainActor @discardableResult
    func guardedScheduleFile(_ file: AVAudioFile) -> Bool {
        AVFAudioGuard.attempt("scheduleFile") { self.scheduleFile(file, at: nil) }
    }

    @MainActor @discardableResult
    func guardedScheduleSegment(_ file: AVAudioFile, startingFrame: AVAudioFramePosition, frameCount: AVAudioFrameCount) -> Bool {
        AVFAudioGuard.attempt("scheduleSegment") {
            self.scheduleSegment(file, startingFrame: startingFrame, frameCount: frameCount, at: nil)
        }
    }

    @MainActor @discardableResult
    func guardedScheduleLoopingBuffer(_ buffer: AVAudioPCMBuffer) -> Bool {
        AVFAudioGuard.attempt("scheduleBuffer") {
            self.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        }
    }
}

// MARK: - AVAudioEngine

extension AVAudioEngine {
    @MainActor @discardableResult
    func guardedAttach(_ node: AVAudioNode) -> Bool {
        AVFAudioGuard.attempt("attach") { self.attach(node) }
    }

    @MainActor @discardableResult
    func guardedConnect(_ source: AVAudioNode, to destination: AVAudioNode, format: AVAudioFormat?) -> Bool {
        AVFAudioGuard.attempt("connect") { self.connect(source, to: destination, format: format) }
    }

    @MainActor @discardableResult
    func guardedDisconnectNodeOutput(_ node: AVAudioNode) -> Bool {
        AVFAudioGuard.attempt("disconnectNodeOutput") { self.disconnectNodeOutput(node) }
    }

    /// `start()` is a throwing API, but it ALSO raises (not throws) when the output hardware
    /// format is transiently invalid — `IsFormatSampleRateAndChannelCountValid(outputHWFormat)`
    /// is the assertion that fires when a Bluetooth route drops mid-restart. Both failure modes
    /// come back as `false`.
    @MainActor @discardableResult
    func guardedStart() -> Bool {
        var started = false
        let completed = AVFAudioGuard.attempt("start") {
            do {
                try self.start()
                started = true
            } catch {
                Logger.audio.error("engine start failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return completed && started
    }
}
