import AVFoundation

/// One independent playback deck — an `AVAudioPlayerNode` feeding a per-deck submix, that can
/// play either a real downloaded file or the M0 synth loop, with its own gain. The dual-deck
/// `Player` owns two of these and crossfades between them by ramping their `volume`.
///
/// **Why a per-deck `deckMixer`:** real files have varying processing formats, so the player node
/// sometimes has to be reconnected with a new input format. Routing each deck through its OWN
/// mixer keeps that reconnection isolated to this deck's submix — it never perturbs the shared
/// main mixer or the other deck's live render (which would glitch an in-progress crossfade). It
/// also gives M3/M4 a natural place to insert per-deck EQ / time-pitch later.
@MainActor
final class Deck {
    let playerNode = AVAudioPlayerNode()
    /// Tempo shifter for beatmatching — changes tempo without affecting pitch. Sits in this deck's
    /// isolated submix so retempo-ing the incoming track never disturbs the outgoing deck.
    private let timePitch = AVAudioUnitTimePitch()
    private let deckMixer = AVAudioMixerNode()

    private let engine: AVAudioEngine
    private let synthFormat: AVAudioFormat
    /// Current `playerNode → deckMixer` input format.
    private var inputFormat: AVAudioFormat

    /// The file currently scheduled, when this deck is playing a real downloaded track.
    private(set) var audioFile: AVAudioFile?
    /// The track currently loaded on this deck.
    private(set) var track: Track?
    /// Duration the player's clock / auto-advance should use. Never zero once a track is loaded
    /// (un-prepared tracks fall back to a sane default so advance logic still engages).
    private(set) var loadedDuration: TimeInterval = 0

    init(engine: AVAudioEngine, mainMixer: AVAudioMixerNode, synthFormat: AVAudioFormat) {
        self.engine = engine
        self.synthFormat = synthFormat
        self.inputFormat = synthFormat
        engine.attach(playerNode)
        engine.attach(timePitch)
        engine.attach(deckMixer)
        engine.connect(playerNode, to: timePitch, format: synthFormat)
        engine.connect(timePitch, to: deckMixer, format: synthFormat)
        engine.connect(deckMixer, to: mainMixer, format: synthFormat) // fixed; never reconnected
    }

    /// Output gain into the mixer (0...1). The crossfade ramps this.
    var volume: Float {
        get { playerNode.volume }
        set { playerNode.volume = newValue }
    }

    /// Tempo multiplier for beatmatching (1.0 = original tempo; pitch is preserved).
    var rate: Float {
        get { timePitch.rate }
        set { timePitch.rate = newValue }
    }

    /// Loads `track` (real file if ready, else synth loop) and schedules it, but does NOT start
    /// playback. Returns the duration the clock should use.
    @discardableResult
    func load(_ track: Track) -> TimeInterval {
        playerNode.stop()
        timePitch.rate = 1 // reset any beatmatch stretch from a previous track on this deck
        self.track = track

        if let url = readyFileURL(for: track), let file = try? AVAudioFile(forReading: url) {
            audioFile = file
            setInputFormat(file.processingFormat)
            playerNode.scheduleFile(file, at: nil)
            let fileDuration = Double(file.length) / file.processingFormat.sampleRate
            if track.durationSeconds <= 0 { track.durationSeconds = fileDuration }
            loadedDuration = track.durationSeconds > 0 ? track.durationSeconds : fileDuration
        } else {
            audioFile = nil
            setInputFormat(synthFormat)
            let buffer = ToneSynth.makeLoop(seed: track.gradientSeed, format: synthFormat)
            playerNode.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            // Un-prepared tracks (e.g. a still-downloading YouTube item) can have durationSeconds 0;
            // fall back to a sane length so the clock and auto-advance still work.
            loadedDuration = track.durationSeconds > 0 ? track.durationSeconds : 30
        }
        return loadedDuration
    }

    func play() { playerNode.play() }
    func pause() { playerNode.pause() }

    /// Stops and clears the deck so it can be reused for the next track.
    func stop() {
        playerNode.stop()
        audioFile = nil
        track = nil
        loadedDuration = 0
    }

    /// Seconds elapsed since this deck last (re)started.
    var elapsed: TimeInterval {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return 0 }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    /// Frame-accurate seek for a real-file deck. Returns `false` for a synth deck.
    func seekRealFile(to seconds: TimeInterval) -> Bool {
        guard let file = audioFile else { return false }
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(seconds * sampleRate)
        guard startFrame < file.length else { return false }
        let remaining = AVAudioFrameCount(file.length - startFrame)
        playerNode.stop()
        playerNode.scheduleSegment(file, startingFrame: startFrame, frameCount: remaining, at: nil)
        return true
    }

    private func readyFileURL(for track: Track) -> URL? {
        guard track.prepState == .ready, let relativePath = track.localRelativePath else { return nil }
        let url = AudioCache.url(forRelativePath: relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Re-points `playerNode → deckMixer` at `format` when it changes. Only touches THIS deck's
    /// isolated submix (the `deckMixer → mainMixer` link stays fixed), so it never disrupts the
    /// other deck even mid-crossfade. No-op when the format is unchanged — the common case, since
    /// itag-140 AAC and the synth are both 44.1 kHz stereo.
    private func setInputFormat(_ format: AVAudioFormat) {
        guard format != inputFormat else { return }
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(timePitch)
        engine.connect(playerNode, to: timePitch, format: format)
        engine.connect(timePitch, to: deckMixer, format: format)
        inputFormat = format
    }
}
