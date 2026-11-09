import AVFoundation
import ContinuityCore
import Domain
import os

/// One playback deck. Plays a track as **two stems** (vocals + accompaniment) when they've been
/// separated, or as a single file / synth loop otherwise — through a shared per-deck chain:
///
///   vocalsPlayer ┐
///                ├─ stemMixer ─ timePitch (beatmatch) ─ deckMixer (crossfade gain) ─ mainMixer
///   accompPlayer ┘
///
/// Per-stem gains (`vocalsGain` / `accompanimentGain`) let a transition duck the outgoing vocals
/// under the incoming instrumental — the M4 flagship move. For a non-stem track the whole mix plays
/// on `accompPlayer` and `vocalsPlayer` stays silent.
///
/// Every AVFAudio node call goes through `AVFAudioGuard` (see that file): the engine can stop
/// between any `isRunning` check and the call that follows it, and AVFAudio reports that with
/// an Objective-C exception Swift cannot catch. Methods here therefore report success as a
/// `Bool` instead of assuming it, and the `Player` treats `false` like an engine stop.
@MainActor
final class Deck {
    private let vocalsPlayer = AVAudioPlayerNode()
    private let accompPlayer = AVAudioPlayerNode()
    private let stemMixer = AVAudioMixerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let eq = AVAudioUnitEQ(numberOfBands: 1)   // low-shelf for the transition bass-swap
    private let deckMixer = AVAudioMixerNode()

    private let engine: AVAudioEngine
    private let synthFormat: AVAudioFormat
    /// Current `accompPlayer → stemMixer` connection format (varies with single-file content).
    private var accompFormat: AVAudioFormat
    /// Host-time boundary of the current engine run. A render timestamp older than this belongs
    /// to a stopped engine and must never authorize `play(at:)`.
    private var engineStartedAtHostTime: UInt64 = 0

    private(set) var track: Track?
    private(set) var loadedDuration: TimeInterval = 0
    /// True when this deck loaded separated stems (so vocal-aware transitions apply).
    private(set) var hasStems = false
    /// Distinguishes a failed real-file reschedule from a synth deck, where seeking is unsupported.
    var hasRealFile: Bool { accompFile != nil }
    /// Engine stops invalidate player-node schedules even though this Deck still holds its files.
    private(set) var needsRescheduleAfterEngineStart = false

    private var accompFile: AVAudioFile?   // drives accompPlayer (accompaniment stem, or whole mix)
    private var vocalsFile: AVAudioFile?   // drives vocalsPlayer (vocals stem), stem mode only

    init(engine: AVAudioEngine, mainMixer: AVAudioMixerNode, synthFormat: AVAudioFormat) {
        self.engine = engine
        self.synthFormat = synthFormat
        self.accompFormat = synthFormat
        for node in [vocalsPlayer, accompPlayer, stemMixer, timePitch, eq, deckMixer] as [AVAudioNode] {
            engine.guardedAttach(node)
        }
        engine.guardedConnect(vocalsPlayer, to: stemMixer, format: synthFormat)
        engine.guardedConnect(accompPlayer, to: stemMixer, format: synthFormat)
        engine.guardedConnect(stemMixer, to: timePitch, format: synthFormat)
        // Low-shelf EQ sits after the tempo unit; its gain is ramped during a blend to swap bass.
        let low = eq.bands[0]
        low.filterType = .lowShelf
        low.frequency = 120
        low.gain = 0
        low.bypass = false
        engine.guardedConnect(timePitch, to: eq, format: synthFormat)
        engine.guardedConnect(eq, to: deckMixer, format: synthFormat)
        engine.guardedConnect(deckMixer, to: mainMixer, format: synthFormat) // fixed; never reconnected
    }

    func markEngineStarted(at hostTime: UInt64) {
        engineStartedAtHostTime = hostTime
        needsRescheduleAfterEngineStart = track != nil
    }

    /// Overall deck output gain — the crossfade ramps this.
    var volume: Float {
        get { deckMixer.outputVolume }
        set { deckMixer.outputVolume = Deck.gain(newValue) }
    }
    /// Vocals-stem gain (for ducking). No effect on a non-stem deck.
    var vocalsGain: Float {
        get { vocalsPlayer.volume }
        set { vocalsPlayer.volume = Deck.gain(newValue) }
    }
    /// Accompaniment-stem gain (also the whole-mix gain for a non-stem deck).
    var accompanimentGain: Float {
        get { accompPlayer.volume }
        set { accompPlayer.volume = Deck.gain(newValue) }
    }
    /// Tempo multiplier for beatmatching (pitch preserved). Clamped: the time-pitch unit
    /// raises on values outside its range, and a NaN ratio from a bad BPM pair is not a tempo.
    var rate: Float {
        get { timePitch.rate }
        set { timePitch.rate = TimePitchLimits.clampRate(newValue) }
    }
    /// Pitch offset in cents (100 = one semitone), for harmonic mixing. Tempo is unaffected.
    var pitchCents: Float {
        get { timePitch.pitch }
        set { timePitch.pitch = TimePitchLimits.clampPitchCents(newValue) }
    }
    /// Low-shelf gain (dB) on this deck's low end. 0 = flat; negative cuts bass. Ramped during a
    /// blend so the incoming bassline fades in instead of stacking on the outgoing one.
    var bassGainDB: Float {
        get { eq.bands[0].gain }
        set { eq.bands[0].gain = newValue.isFinite ? min(max(newValue, -96), 24) : 0 }
    }
    /// Loudness-leveling makeup gain (linear). Lives on the stem mixer so it stacks independently
    /// of the crossfade (deck mixer) and vocal ducking (player nodes). 1 = no leveling.
    var loudnessGain: Float {
        get { stemMixer.outputVolume }
        set { stemMixer.outputVolume = Deck.gain(newValue, upperBound: 4) }
    }

    /// Mixer/player volumes accept 0…1 (players and mixers clamp silently, but a NaN passes
    /// through to the render thread). Loudness makeup may exceed unity, hence the bound.
    private static func gain(_ value: Float, upperBound: Float = 1) -> Float {
        guard value.isFinite else { return upperBound >= 1 ? 1 : upperBound }
        return min(max(value, 0), upperBound)
    }

    /// Loads `track` and schedules it from the start. Returns the resolved duration (0 when
    /// nothing could be scheduled — the caller must not `play()` an unscheduled deck as if it
    /// were playing; `needsRescheduleAfterEngineStart` is left set so recovery retries).
    @discardableResult
    func load(_ track: Track) -> TimeInterval {
        stop()
        self.track = track
        timePitch.rate = 1
        timePitch.pitch = 0
        volume = 1; vocalsGain = 1; accompanimentGain = 1; bassGainDB = 0; loudnessGain = 1

        let scheduled: Bool
        if track.hasStems,
           let vURL = stemURL(track.vocalsRelativePath), let aURL = stemURL(track.accompanimentRelativePath),
           let vFile = try? AVAudioFile(forReading: vURL), let aFile = try? AVAudioFile(forReading: aURL) {
            // Stem mode: vocals + accompaniment, sample-aligned (both derived from the same mix).
            hasStems = true
            vocalsFile = vFile; accompFile = aFile
            setAccompFormat(aFile.processingFormat) // stems are 44.1k float → matches synthFormat
            let v = vocalsPlayer.guardedScheduleFile(vFile)
            let a = accompPlayer.guardedScheduleFile(aFile)
            scheduled = v && a
            loadedDuration = resolveDuration(track, file: aFile)
        } else if let url = readyFileURL(for: track), let file = try? AVAudioFile(forReading: url) {
            hasStems = false
            accompFile = file; vocalsFile = nil
            setAccompFormat(file.processingFormat)
            scheduled = accompPlayer.guardedScheduleFile(file)
            loadedDuration = resolveDuration(track, file: file)
        } else {
            hasStems = false
            accompFile = nil; vocalsFile = nil
            setAccompFormat(synthFormat)
            let buffer = ToneSynth.makeLoop(seed: track.gradientSeed, format: synthFormat)
            scheduled = accompPlayer.guardedScheduleLoopingBuffer(buffer)
            loadedDuration = track.durationSeconds > 0 ? track.durationSeconds : 30
        }
        // A failed schedule means the engine died under us; flag it exactly like an engine
        // stop so `ensureCurrentLoaded` reschedules before the next play.
        needsRescheduleAfterEngineStart = !scheduled
        return scheduled ? loadedDuration : 0
    }

    /// Starts (or resumes) the scheduled audio. Returns false when AVFAudio refused — the engine
    /// stopped between the caller's check and this call — in which case nothing is playing and
    /// the caller must stage its position and pause instead of reporting `isPlaying`.
    @discardableResult
    func play() -> Bool {
        // AVAudioPlayerNode.play() raises ("_engine->IsRunning()") when the engine was stopped
        // out from under us — interruptions, route changes, config resets. Fail fast here; the
        // guard below catches the race where it stops after this line.
        guard engine.isRunning else { return false }
        if hasStems {
            // Two bare play() calls can land on different render quanta, starting the stems
            // several ms apart — and nothing ever re-aligns them. Anchor both to one shared
            // host-clock start just far enough out to cover the second call.
            //
            // Only when the render clock is FRESH, not merely host-time-valid. Two traps here:
            // - A node that hasn't seen an IO cycle yet (first start after engine build) has no
            //   render time → play(at:) raises the AVFAudio start-time exception.
            // - After a stop → engine-restart (Siri/interruption recovery, route or config
            //   changes), lastRenderTime can be *valid but stale* — a host timestamp from the
            //   pre-interruption timeline. Anchoring to it puts the start time in the PAST,
            //   which raises the same exception mid-song whenever the system pokes the audio
            //   environment. `PlaybackClock.isRenderClockUsable` encodes the rule (Core-tested).
            // Otherwise fall back to two bare play() calls — on a freshly (re)started engine they
            // land on the same quantum in practice. Should the anchored start still be refused,
            // the guard reports it and we fall back the same way instead of dying.
            let now = mach_absolute_time()
            if let render = accompPlayer.lastRenderTime, render.isHostTimeValid,
               PlaybackClock.isRenderClockUsable(
                   renderHostTime: render.hostTime,
                   engineStartedAtHostTime: engineStartedAtHostTime,
                   now: now,
                   maximumAge: AVAudioTime.hostTime(forSeconds: 1.0)
               ) {
                let start = AVAudioTime(hostTime: now + AVAudioTime.hostTime(forSeconds: 0.03))
                if accompPlayer.guardedPlay(at: start), vocalsPlayer.guardedPlay(at: start) {
                    return true
                }
                Logger.audio.error("anchored stem start refused — falling back to immediate start")
            }
            let a = accompPlayer.guardedPlay()
            let v = vocalsPlayer.guardedPlay()
            return a && v
        }
        return accompPlayer.guardedPlay()
    }

    func pause() {
        guard engine.isRunning else { return }
        accompPlayer.guardedPause()
        if hasStems { vocalsPlayer.guardedPause() }
    }

    func stop() {
        // A system configuration change can stop the engine after its notification was delivered.
        // `stop()` on a node of a stopped engine raises; the guard absorbs the race the check misses.
        if engine.isRunning {
            accompPlayer.guardedStop()
            vocalsPlayer.guardedStop()
        }
        accompFile = nil; vocalsFile = nil; track = nil
        loadedDuration = 0; hasStems = false
        needsRescheduleAfterEngineStart = false
    }

    /// Seconds elapsed since this deck last (re)started (from the always-present accompaniment).
    ///
    /// Defensive about the render clock, because this value is the root of every number the app
    /// computes about playback. Around a route or configuration change — AirPods connecting, a
    /// car stereo, a jostled cable — the node's time base can briefly report an unset sample
    /// rate or a sample time from the previous engine run. `sampleTime / 0` is `.infinity` in
    /// Swift, not an error, so that used to flow into `Player.position` and from there into
    /// `AVAudioFramePosition(seconds * sampleRate)`, which **traps** on a non-finite double, and
    /// into SwiftUI frames and `Shape.trim`, which trap on one too.
    ///
    /// That is the crash class that clusters "when the phone is moving": moving is when routes
    /// change. An unusable clock now reads as 0 — the position simply doesn't advance for a
    /// tick — instead of poisoning everything downstream (`PlaybackClock.elapsedSeconds`).
    var elapsed: TimeInterval {
        guard let nodeTime = accompPlayer.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = accompPlayer.playerTime(forNodeTime: nodeTime),
              playerTime.isSampleTimeValid else { return 0 }
        return PlaybackClock.elapsedSeconds(sampleTime: playerTime.sampleTime, sampleRate: playerTime.sampleRate)
    }

    /// Frame-accurate seek for a real-file (or stem) deck. Returns `false` for a synth deck or
    /// when the engine refused the schedule.
    func seekRealFile(to seconds: TimeInterval) -> Bool {
        guard engine.isRunning, let aFile = accompFile else { return false }
        var ok = scheduleSegment(accompPlayer, file: aFile, from: seconds)
        if hasStems, let vFile = vocalsFile {
            ok = scheduleSegment(vocalsPlayer, file: vFile, from: seconds) && ok
        }
        needsRescheduleAfterEngineStart = !ok
        return ok
    }

    private func scheduleSegment(_ player: AVAudioPlayerNode, file: AVAudioFile, from seconds: TimeInterval) -> Bool {
        // `PlaybackClock.segment` clamps into the file before converting (Double →
        // AVAudioFramePosition traps on infinity/NaN/out of range; scheduleSegment raises on a
        // negative start or empty range). A request that isn't a real position in this file
        // starts it from the beginning; one past the end schedules nothing but is not an error.
        guard player.guardedStop() else { return false }
        guard let segment = PlaybackClock.segment(
            seconds: seconds,
            sampleRate: file.processingFormat.sampleRate,
            frameLength: file.length
        ) else { return true }
        return player.guardedScheduleSegment(
            file, startingFrame: segment.startFrame, frameCount: segment.frameCount
        )
    }

    private func resolveDuration(_ track: Track, file: AVAudioFile) -> TimeInterval {
        // Mirror `scheduleSegment`'s sample-rate floor: an unset rate yields infinity, which
        // used to land on `Track.durationSeconds` and trap `Theme.time` / scrubber layout.
        let fileDuration = PlaybackClock.durationSeconds(
            frameLength: file.length, sampleRate: file.processingFormat.sampleRate
        )
        if track.durationSeconds <= 0, fileDuration > 0 { track.durationSeconds = fileDuration }
        let resolved = track.durationSeconds > 0 ? track.durationSeconds : fileDuration
        return resolved.isFinite && resolved > 0 ? resolved : 0
    }

    private func stemURL(_ relativePath: String?) -> URL? {
        guard let relativePath else { return nil }
        let url = StemCache.url(forRelativePath: relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func readyFileURL(for track: Track) -> URL? {
        guard track.prepState == .ready, let relativePath = track.localRelativePath else { return nil }
        let url = AudioCache.url(forRelativePath: relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Re-points `accompPlayer → stemMixer` at `format` when it changes — isolated to this deck's
    /// submix (mixers convert their inputs), so it never disturbs the other deck mid-crossfade.
    /// A refused reconnect keeps the previous format: the mixer still converts, so the file
    /// plays (possibly resampled) instead of the app dying on a format assertion.
    private func setAccompFormat(_ format: AVAudioFormat) {
        guard format != accompFormat else { return }
        guard engine.guardedDisconnectNodeOutput(accompPlayer) else { return }
        if engine.guardedConnect(accompPlayer, to: stemMixer, format: format) {
            accompFormat = format
        } else if engine.guardedConnect(accompPlayer, to: stemMixer, format: accompFormat) {
            Logger.audio.error("accompaniment format change refused — kept previous connection format")
        }
    }
}
