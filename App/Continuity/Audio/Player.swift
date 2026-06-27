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
    private let format: AVAudioFormat
    private var displayTimer: Timer?
    /// Offset that lets `seek` move the clock without true audio seeking (M0 synth is a loop).
    private var baselineSeconds: TimeInterval = 0

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
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
            ensureRunning()
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
        baselineSeconds = clamped - nodeElapsed()
        position = clamped
    }

    // MARK: Internals

    private func ensureRunning() {
        if !engine.isRunning { try? engine.start() }
    }

    private func startCurrent() {
        guard let track = currentTrack else { return }
        playerNode.stop()
        ensureRunning()
        let buffer = ToneSynth.makeLoop(seed: track.gradientSeed, format: format)
        playerNode.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        baselineSeconds = 0
        position = 0
        playerNode.play()
        isPlaying = true
        startTimer()
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
