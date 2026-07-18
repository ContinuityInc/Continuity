import AVFoundation
import Domain

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

    private(set) var track: Track?
    private(set) var loadedDuration: TimeInterval = 0
    /// True when this deck loaded separated stems (so vocal-aware transitions apply).
    private(set) var hasStems = false

    private var accompFile: AVAudioFile?   // drives accompPlayer (accompaniment stem, or whole mix)
    private var vocalsFile: AVAudioFile?   // drives vocalsPlayer (vocals stem), stem mode only

    init(engine: AVAudioEngine, mainMixer: AVAudioMixerNode, synthFormat: AVAudioFormat) {
        self.engine = engine
        self.synthFormat = synthFormat
        self.accompFormat = synthFormat
        for node in [vocalsPlayer, accompPlayer] as [AVAudioNode] { engine.attach(node) }
        engine.attach(stemMixer); engine.attach(timePitch); engine.attach(eq); engine.attach(deckMixer)
        engine.connect(vocalsPlayer, to: stemMixer, format: synthFormat)
        engine.connect(accompPlayer, to: stemMixer, format: synthFormat)
        engine.connect(stemMixer, to: timePitch, format: synthFormat)
        // Low-shelf EQ sits after the tempo unit; its gain is ramped during a blend to swap bass.
        let low = eq.bands[0]
        low.filterType = .lowShelf
        low.frequency = 120
        low.gain = 0
        low.bypass = false
        engine.connect(timePitch, to: eq, format: synthFormat)
        engine.connect(eq, to: deckMixer, format: synthFormat)
        engine.connect(deckMixer, to: mainMixer, format: synthFormat) // fixed; never reconnected
    }

    /// Overall deck output gain — the crossfade ramps this.
    var volume: Float {
        get { deckMixer.outputVolume }
        set { deckMixer.outputVolume = newValue }
    }
    /// Vocals-stem gain (for ducking). No effect on a non-stem deck.
    var vocalsGain: Float {
        get { vocalsPlayer.volume }
        set { vocalsPlayer.volume = newValue }
    }
    /// Accompaniment-stem gain (also the whole-mix gain for a non-stem deck).
    var accompanimentGain: Float {
        get { accompPlayer.volume }
        set { accompPlayer.volume = newValue }
    }
    /// Tempo multiplier for beatmatching (pitch preserved).
    var rate: Float {
        get { timePitch.rate }
        set { timePitch.rate = newValue }
    }
    /// Pitch offset in cents (100 = one semitone), for harmonic mixing. Tempo is unaffected.
    var pitchCents: Float {
        get { timePitch.pitch }
        set { timePitch.pitch = newValue }
    }
    /// Low-shelf gain (dB) on this deck's low end. 0 = flat; negative cuts bass. Ramped during a
    /// blend so the incoming bassline fades in instead of stacking on the outgoing one.
    var bassGainDB: Float {
        get { eq.bands[0].gain }
        set { eq.bands[0].gain = newValue }
    }
    /// Loudness-leveling makeup gain (linear). Lives on the stem mixer so it stacks independently
    /// of the crossfade (deck mixer) and vocal ducking (player nodes). 1 = no leveling.
    var loudnessGain: Float {
        get { stemMixer.outputVolume }
        set { stemMixer.outputVolume = newValue }
    }

    @discardableResult
    func load(_ track: Track) -> TimeInterval {
        stop()
        self.track = track
        timePitch.rate = 1
        timePitch.pitch = 0
        volume = 1; vocalsGain = 1; accompanimentGain = 1; bassGainDB = 0; loudnessGain = 1

        if track.hasStems,
           let vURL = stemURL(track.vocalsRelativePath), let aURL = stemURL(track.accompanimentRelativePath),
           let vFile = try? AVAudioFile(forReading: vURL), let aFile = try? AVAudioFile(forReading: aURL) {
            // Stem mode: vocals + accompaniment, sample-aligned (both derived from the same mix).
            hasStems = true
            vocalsFile = vFile; accompFile = aFile
            setAccompFormat(aFile.processingFormat) // stems are 44.1k float → matches synthFormat
            vocalsPlayer.scheduleFile(vFile, at: nil)
            accompPlayer.scheduleFile(aFile, at: nil)
            loadedDuration = resolveDuration(track, file: aFile)
        } else if let url = readyFileURL(for: track), let file = try? AVAudioFile(forReading: url) {
            hasStems = false
            accompFile = file; vocalsFile = nil
            setAccompFormat(file.processingFormat)
            accompPlayer.scheduleFile(file, at: nil)
            loadedDuration = resolveDuration(track, file: file)
        } else {
            hasStems = false
            accompFile = nil; vocalsFile = nil
            setAccompFormat(synthFormat)
            let buffer = ToneSynth.makeLoop(seed: track.gradientSeed, format: synthFormat)
            accompPlayer.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            loadedDuration = track.durationSeconds > 0 ? track.durationSeconds : 30
        }
        return loadedDuration
    }

    func play() {
        // AVAudioPlayerNode.play() throws an ObjC exception ("_engine->IsRunning()") when the
        // engine was stopped out from under us — interruptions, route changes, config resets.
        // No-op instead; the Player's audio-environment recovery reschedules and replays.
        guard engine.isRunning else { return }
        if hasStems {
            // Two bare play() calls can land on different render quanta, starting the stems
            // several ms apart — and nothing ever re-aligns them. Anchor both to one shared
            // host-clock start just far enough out to cover the second call.
            //
            // Only when the render clock is FRESH, not merely host-time-valid. Two traps here:
            // - A node that hasn't seen an IO cycle yet (first start after engine build) has no
            //   render time → play(at:) throws the AVFAudio start-time exception.
            // - After a stop → engine-restart (Siri/interruption recovery, route or config
            //   changes), lastRenderTime can be *valid but stale* — a host timestamp from the
            //   pre-interruption timeline. Anchoring to it puts the start time in the PAST,
            //   which raises the same uncatchable exception → SIGABRT mid-song whenever the
            //   system pokes the audio environment.
            // So: require a render cycle within the last second (proof the engine is actively
            // rendering) and anchor to NOW, not to the render timestamp. Otherwise fall back to
            // two bare play() calls — on a freshly (re)started engine they land on the same
            // quantum in practice.
            let now = mach_absolute_time()
            if let render = accompPlayer.lastRenderTime, render.isHostTimeValid,
               render.hostTime <= now,
               now - render.hostTime < AVAudioTime.hostTime(forSeconds: 1.0) {
                let start = AVAudioTime(hostTime: now + AVAudioTime.hostTime(forSeconds: 0.03))
                accompPlayer.play(at: start)
                vocalsPlayer.play(at: start)
            } else {
                accompPlayer.play()
                vocalsPlayer.play()
            }
        } else {
            accompPlayer.play()
        }
    }

    func pause() {
        guard engine.isRunning else { return }
        accompPlayer.pause()
        if hasStems { vocalsPlayer.pause() }
    }

    func stop() {
        accompPlayer.stop(); vocalsPlayer.stop()
        accompFile = nil; vocalsFile = nil; track = nil
        loadedDuration = 0; hasStems = false
    }

    /// Seconds elapsed since this deck last (re)started (from the always-present accompaniment).
    var elapsed: TimeInterval {
        guard let nodeTime = accompPlayer.lastRenderTime,
              let playerTime = accompPlayer.playerTime(forNodeTime: nodeTime) else { return 0 }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    /// Frame-accurate seek for a real-file (or stem) deck. Returns `false` for a synth deck.
    func seekRealFile(to seconds: TimeInterval) -> Bool {
        guard let aFile = accompFile else { return false }
        scheduleSegment(accompPlayer, file: aFile, from: seconds)
        if hasStems, let vFile = vocalsFile {
            scheduleSegment(vocalsPlayer, file: vFile, from: seconds)
        }
        return true
    }

    private func scheduleSegment(_ player: AVAudioPlayerNode, file: AVAudioFile, from seconds: TimeInterval) {
        let startFrame = AVAudioFramePosition(seconds * file.processingFormat.sampleRate)
        player.stop()
        guard startFrame < file.length else { return }
        player.scheduleSegment(file, startingFrame: startFrame,
                               frameCount: AVAudioFrameCount(file.length - startFrame), at: nil)
    }

    private func resolveDuration(_ track: Track, file: AVAudioFile) -> TimeInterval {
        let fileDuration = Double(file.length) / file.processingFormat.sampleRate
        if track.durationSeconds <= 0 { track.durationSeconds = fileDuration }
        return track.durationSeconds > 0 ? track.durationSeconds : fileDuration
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
    private func setAccompFormat(_ format: AVAudioFormat) {
        guard format != accompFormat else { return }
        engine.disconnectNodeOutput(accompPlayer)
        engine.connect(accompPlayer, to: stemMixer, format: format)
        accompFormat = format
    }
}
