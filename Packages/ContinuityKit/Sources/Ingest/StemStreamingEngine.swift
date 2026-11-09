import AVFoundation
import ContinuityCore
import Foundation

/// Backend-agnostic streaming stem pipeline: decode → windowed inference → overlap-add →
/// incremental AAC encode. Peak memory stays O(segment) regardless of track length.
///
/// Both `OnnxStemSeparator` and the Phase 3a `CoreMLStemSeparator` spike feed this the same
/// `WindowInference` seam so A/B runs share decode/OLA/encode and only swap the model call.
enum StemStreamingEngine {
    typealias WindowInference = @Sendable ([Float]) throws -> [Float]

    /// Runs the full streaming separation into `vocalsOut` / `accompanimentOut`.
    /// `shouldAbort` is checked before every window (memory-warning / budget abort).
    /// `onWindow` is optional instrumentation (RSS breadcrumbs, harness counters).
    static func separate(
        inputURL: URL,
        vocalsOut: URL,
        accompanimentOut: URL,
        runWindow: WindowInference,
        shouldAbort: () -> Bool = { false },
        windowFloorMB: Int = StemSeparationBudget.windowFloorMB,
        headroomMB: () -> Int = { MemoryFootprint.headroomMB },
        onWindow: ((Int) -> Void)? = nil
    ) throws -> StemPaths {
        let sampleRate = StemWindowSpec.sampleRate
        let segment = StemWindowSpec.segmentFrames
        let channels = StemWindowSpec.channelCount
        let maxFrames = Int(StemWindowSpec.maxSeparationSeconds * sampleRate)

        let decoder = try StreamingStereoDecoder(url: inputURL, sampleRate: sampleRate)
        let vocalsFile = try openStemFile(vocalsOut, sampleRate: sampleRate)
        let accFile = try openStemFile(accompanimentOut, sampleRate: sampleRate)
        do {
            let frames = try runStreaming(
                decoder: decoder,
                runWindow: runWindow,
                maxFrames: maxFrames,
                segment: segment,
                channels: channels,
                vocalsFile: vocalsFile,
                accFile: accFile,
                shouldAbort: shouldAbort,
                windowFloorMB: windowFloorMB,
                headroomMB: headroomMB,
                onWindow: onWindow)
            guard frames > 0 else { throw StemSeparationError.decode("no audio frames") }
        } catch {
            try? FileManager.default.removeItem(at: vocalsOut)
            try? FileManager.default.removeItem(at: accompanimentOut)
            throw error
        }
        MemoryFootprint.breadcrumb("separation done")
        return StemPaths(vocals: vocalsOut, accompaniment: accompanimentOut)
    }

    private static func runStreaming(
        decoder: StreamingStereoDecoder,
        runWindow: WindowInference,
        maxFrames: Int,
        segment: Int,
        channels: Int,
        vocalsFile: AVAudioFile,
        accFile: AVAudioFile,
        shouldAbort: () -> Bool,
        windowFloorMB: Int,
        headroomMB: () -> Int,
        onWindow: ((Int) -> Void)?
    ) throws -> Int {
        let ola = StreamingOverlapAdd(channels: channels, segment: segment, overlap: segment / 4)
        let stride = ola.stride

        var mixL = [Float](), mixR = [Float]()
        var flushed = 0
        var decodedEnd = 0
        var atEOF = false
        var input = [Float](repeating: 0, count: channels * segment)

        var start = 0
        var windowCount = 0
        while true {
            while !atEOF && decodedEnd < start + segment {
                if let chunk = try decoder.next() {
                    var takeCount = chunk.left.count
                    if decodedEnd + takeCount >= maxFrames {
                        takeCount = maxFrames - decodedEnd
                        atEOF = true
                    }
                    mixL.append(contentsOf: chunk.left.prefix(takeCount))
                    mixR.append(contentsOf: chunk.right.prefix(takeCount))
                    decodedEnd += takeCount
                } else {
                    atEOF = true
                }
            }
            if start >= decodedEnd { break }

            let length = min(segment, decodedEnd - start)
            let offset = start - flushed
            for i in 0..<length {
                input[i] = mixL[offset + i]
                input[segment + i] = mixR[offset + i]
            }
            for i in length..<segment {
                input[i] = 0
                input[segment + i] = 0
            }

            if shouldAbort() {
                throw StemSeparationError.inference("aborted under memory pressure")
            }
            let headroom = headroomMB()
            if headroom < windowFloorMB {
                throw StemSeparationError.inference("aborted: \(headroom) MB headroom below window floor")
            }

            onWindow?(windowCount)
            windowCount += 1
            let vocals = try runWindow(input)
            guard vocals.count >= channels * segment else {
                throw StemSeparationError.inference("short vocals output: \(vocals.count)")
            }
            ola.add(start: start, length: length) { c, i in vocals[c * segment + i] }

            start += stride

            let finalUpTo = min(start, decodedEnd)
            if finalUpTo > flushed {
                let voc = ola.drain(upTo: finalUpTo)
                let n = finalUpTo - flushed
                var accL = [Float](repeating: 0, count: n)
                var accR = [Float](repeating: 0, count: n)
                for i in 0..<n {
                    accL[i] = mixL[i] - voc[0][i]
                    accR[i] = mixR[i] - voc[1][i]
                }
                try append(to: vocalsFile, left: voc[0], right: voc[1], sampleRate: StemWindowSpec.sampleRate)
                try append(to: accFile, left: accL, right: accR, sampleRate: StemWindowSpec.sampleRate)
                mixL.removeFirst(n)
                mixR.removeFirst(n)
                flushed = finalUpTo
            }
            if atEOF && start >= decodedEnd { break }
        }
        return decodedEnd
    }

    private static func openStemFile(_ url: URL, sampleRate: Double) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        do {
            return try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw StemSeparationError.write("open: \(error)")
        }
    }

    private static func append(to file: AVAudioFile, left: [Float], right: [Float],
                               sampleRate: Double) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count)) else {
            throw StemSeparationError.write("buffer")
        }
        buffer.frameLength = AVAudioFrameCount(left.count)
        guard let channelData = buffer.floatChannelData else { throw StemSeparationError.write("channel data") }
        left.withUnsafeBufferPointer { channelData[0].update(from: $0.baseAddress!, count: left.count) }
        right.withUnsafeBufferPointer { channelData[1].update(from: $0.baseAddress!, count: right.count) }
        do {
            try file.write(from: buffer)
        } catch {
            throw StemSeparationError.write("\(error)")
        }
    }
}
