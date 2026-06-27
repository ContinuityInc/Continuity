import AVFoundation
import Observation

/// M0 single-deck playback engine. Owns one `AVAudioEngine` + `AVAudioPlayerNode`, manages a
/// queue, exposes observable transport state, and hard-cuts to the next track when one ends.
///
/// This is intentionally the *single-deck* version. M2 replaces `startCurrent`/auto-advance
/// with a dual-deck `TransitionController` that overlaps and crossfades the two decks.
@MainActor
@Observable
final class Player {
    // MARK: Observable state
    private(set) var queue: [Track] = []
    private(set) var currentIndex: Int = 0
    private(set) var isPlaying: Bool = false
    /// Seconds into the current track (drives the scrubber + clock).
    var position: TimeInterval = 0

    var currentTrack: Track? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }
    var duration: TimeInterval { currentTrack?.durationSeconds ?? 0 }

    // MARK: Engine
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    /// Standard stereo float format used by the M0 synth loop.
    private let format: AVAudioFormat
    /// The format the player node is currently connected to the mixer with. Real audio
    /// files often have a different sample rate / channel layout than `format`, so each
    /// `startCurrent()` reconnects the node when the required format changes.
    private var connectedFormat: AVAudioFormat
    private var displayTimer: Timer?
    /// Offset that lets `seek` move the clock without true audio seeking (M0 synth is a loop).
    private var baselineSeconds: TimeInterval = 0
    /// The audio file currently scheduled when playing a real downloaded track (nil for synth).
    /// Lets `seek` perform a true frame-accurate seek instead of only moving the clock.
    private var currentAudioFile: AVAudioFile?

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        connectedFormat = format
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        configureSession()
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    // MARK: Transport

    func play(tracks: [Track], startAt index: Int) {
        queue = tracks
        currentIndex = max(0, min(index, tracks.count - 1))
        startCurrent()
    }

    func togglePlayPause() {
        guard currentTrack != nil else { return }
        if isPlaying {
            playerNode.pause()
            isPlaying = false
            stopTimer()
        } else {
            guard ensureRunning() else { isPlaying = false; return }
            playerNode.play()
            isPlaying = true
            startTimer()
        }
    }

    func next() {
        guard !queue.isEmpty else { return }
        currentIndex = (currentIndex + 1) % queue.count
        startCurrent()
    }

    func previous() {
        guard !queue.isEmpty else { return }
        // Restart the current track if we're more than 3s in; otherwise go back one.
        if position > 3 {
            startCurrent()
            return
        }
        currentIndex = (currentIndex - 1 + queue.count) % queue.count
        startCurrent()
    }

    func seek(to seconds: TimeInterval) {
        let clamped = max(0, min(seconds, duration))
        if let audioFile = currentAudioFile {
            // Real file: perform a true seek by rescheduling from the target frame.
            seekRealFile(audioFile, to: clamped)
        } else {
            // Synth loop: the audible content is identical at any offset, so just move the clock
            // (baseline offsets the ever-increasing node time).
            baselineSeconds = clamped - nodeElapsed()
            position = clamped
        }
    }

    /// True audio seek for a downloaded file: stop, reschedule the remaining frames from the
    /// target position, and remap the clock so `position` tracks the new offset.
    private func seekRealFile(_ audioFile: AVAudioFile, to seconds: TimeInterval) {
        let sampleRate = audioFile.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(seconds * sampleRate)
        guard startFrame < audioFile.length else {
            // Seeking at/after the end → just advance to the next track.
            next()
            return
        }
        let remaining = AVAudioFrameCount(audioFile.length - startFrame)
        let wasPlaying = isPlaying

        playerNode.stop() // clears the prior schedule and resets the node's sample clock to 0
        playerNode.scheduleSegment(audioFile, startingFrame: startFrame, frameCount: remaining, at: nil)
        // After stop(), nodeElapsed() restarts from 0, so the clock maps node-time 0 → `seconds`.
        baselineSeconds = seconds
        position = seconds

        if wasPlaying {
            guard ensureRunning() else { isPlaying = false; return }
            playerNode.play()
        }
    }

    // MARK: Internals

    /// Ensures the engine is running. Returns `false` if it couldn't be started (e.g. the audio
    /// session couldn't be activated), so callers can avoid entering a silent fake "playing" state.
    @discardableResult
    private func ensureRunning() -> Bool {
        if engine.isRunning { return true }
        try? AVAudioSession.sharedInstance().setActive(true)
        do {
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    private func startCurrent() {
        guard let track = currentTrack else { return }
        playerNode.stop()
        guard ensureRunning() else {
            // Engine couldn't start — show a stopped state rather than a silent "playing" one.
            isPlaying = false
            stopTimer()
            return
        }

        // Prefer a real downloaded file once the track is prepared; otherwise fall back to
        // the M0 synth loop. The file path drives both the audio and the auto-advance clock.
        if !startRealFile(for: track) {
            startSynth(for: track)
        }

        baselineSeconds = 0
        position = 0
        playerNode.play()
        isPlaying = true
        startTimer()
    }

    /// Attempts to schedule the track's downloaded audio file (non-looped). Returns `false`
    /// if there is no ready file or anything throws, so the caller can fall back to the synth.
    private func startRealFile(for track: Track) -> Bool {
        guard let relativePath = track.localRelativePath else { return false }
        let url = AudioCache.url(forRelativePath: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }

        do {
            let audioFile = try AVAudioFile(forReading: url)
            currentAudioFile = audioFile
            // Real files may not match the synth format; reconnect the node to the file's
            // processing format before scheduling so the engine doesn't have to convert.
            reconnect(to: audioFile.processingFormat)
            // Not looped: the file plays once and `tick()` auto-advances at its end.
            playerNode.scheduleFile(audioFile, at: nil)
            // Backfill an unknown duration from the file so the scrubber/auto-advance work.
            if track.durationSeconds <= 0 {
                track.durationSeconds = Double(audioFile.length) / audioFile.processingFormat.sampleRate
            }
            return true
        } catch {
            // Decode/format error — fall back to the synth path.
            currentAudioFile = nil
            return false
        }
    }

    /// Schedules the looped M0 synth phrase for `track`, reconnecting to the synth format if
    /// the node was previously connected to a real file's format.
    private func startSynth(for track: Track) {
        currentAudioFile = nil
        reconnect(to: format)
        let buffer = ToneSynth.makeLoop(seed: track.gradientSeed, format: format)
        playerNode.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
    }

    /// Reconnects the player node to the mixer with `newFormat` when it differs from the
    /// currently-connected one. No-op when the format is unchanged (cheap fast path).
    private func reconnect(to newFormat: AVAudioFormat) {
        guard newFormat != connectedFormat else { return }
        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: newFormat)
        connectedFormat = newFormat
    }

    /// Elapsed seconds reported by the player node since it last started.
    private func nodeElapsed() -> TimeInterval {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return 0 }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func stopTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func tick() {
        guard isPlaying else { return }
        position = baselineSeconds + nodeElapsed()
        if position >= duration - 0.05 {
            // M0: hard cut to the next track. M2 replaces this with a beat-aligned crossfade.
            next()
        }
    }
}
