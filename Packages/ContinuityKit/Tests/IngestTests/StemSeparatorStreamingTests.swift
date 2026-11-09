import XCTest
import AVFoundation
@testable import Ingest

/// Exercises the full streaming separation pipeline (decode → windowed inference → overlap-add →
/// incremental AAC encode) via the fake-inference seam, so no ONNX model download is needed.
/// Runs on the iOS Simulator via `xcodebuild test`.
final class StemSeparatorStreamingTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemSeparatorStreamingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// "Vocals = half the mix" fake model: output shape (2, segment) from the (2, segment) input.
    private static let halfMixInference: OnnxStemSeparator.WindowInference = { input in
        input.map { $0 * 0.5 }
    }

    private func writeInputFile(name: String, seconds: Double, sampleRate: Double = 44_100,
                                channels: AVAudioChannelCount = 2) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: channels, interleaved: false) else {
            throw XCTSkip("format unavailable")
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunkFrames: AVAudioFrameCount = 1 << 16
        var remaining = AVAudioFramePosition(seconds * sampleRate)
        var phase = 0.0
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw XCTSkip("buffer unavailable")
        }
        while remaining > 0 {
            let n = Int(min(AVAudioFramePosition(chunkFrames), remaining))
            buffer.frameLength = AVAudioFrameCount(n)
            for c in 0..<Int(channels) {
                let p = buffer.floatChannelData![c]
                for i in 0..<n {
                    p[i] = Float(sin((phase + Double(i)) * 2 * .pi * 220 / sampleRate)) * 0.5
                }
            }
            phase += Double(n)
            try file.write(from: buffer)
            remaining -= AVAudioFramePosition(n)
        }
        return url
    }

    private func decodeMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            XCTFail("decode buffer"); return []
        }
        try file.read(into: buffer)
        let frames = Int(buffer.frameLength)
        guard let data = buffer.floatChannelData else { return [] }
        var mono = [Float](repeating: 0, count: frames)
        for i in 0..<frames { mono[i] = data[0][i] }
        return mono
    }

    private func rms(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
    }

    /// vocals ≈ mix/2 and accompaniment ≈ mix/2 (energy-wise, post-AAC) for the half-mix fake.
    func testRoundTripStereo() throws {
        let input = try writeInputFile(name: "in.caf", seconds: 20)
        let separator = OnnxStemSeparator(inference: Self.halfMixInference)
        let vocalsOut = tempDir.appendingPathComponent("voc.m4a")
        let accOut = tempDir.appendingPathComponent("acc.m4a")
        let paths = try separator.separate(inputURL: input, vocalsOut: vocalsOut, accompanimentOut: accOut)
        XCTAssertEqual(paths.vocals, vocalsOut)

        let mix = try decodeMono(input)
        let voc = try decodeMono(vocalsOut)
        let acc = try decodeMono(accOut)
        // AAC priming/padding shifts exact sample alignment; compare duration and energy.
        XCTAssertEqual(Double(voc.count), Double(mix.count), accuracy: 4096)
        XCTAssertEqual(Double(acc.count), Double(mix.count), accuracy: 4096)
        // Skip edges (encoder ramp); interior energy of each stem ≈ half the mix's.
        let interior = { (x: [Float]) in x[(x.count / 4)..<(3 * x.count / 4)] }
        let mixRMS = rms(interior(mix))
        XCTAssertGreaterThan(mixRMS, 0.1)
        XCTAssertEqual(rms(interior(voc)) / mixRMS, 0.5, accuracy: 0.05)
        XCTAssertEqual(rms(interior(acc)) / mixRMS, 0.5, accuracy: 0.05)
    }

    /// Mono and non-44.1 kHz inputs go through the streaming AVAudioConverter path.
    func testMonoResampledInput() throws {
        let input = try writeInputFile(name: "mono.caf", seconds: 10, sampleRate: 22_050, channels: 1)
        let separator = OnnxStemSeparator(inference: Self.halfMixInference)
        let vocalsOut = tempDir.appendingPathComponent("voc.m4a")
        let accOut = tempDir.appendingPathComponent("acc.m4a")
        _ = try separator.separate(inputURL: input, vocalsOut: vocalsOut, accompanimentOut: accOut)
        let voc = try decodeMono(vocalsOut)
        // 10 s at the output rate of 44.1 kHz regardless of the input rate.
        XCTAssertEqual(Double(voc.count), 10 * 44_100, accuracy: 8192)
        XCTAssertGreaterThan(rms(voc[voc.count / 4..<voc.count / 2]), 0.05)
    }

    /// Input shorter than one model segment (7.8 s) still produces both stems.
    func testShorterThanOneSegment() throws {
        let input = try writeInputFile(name: "short.caf", seconds: 3)
        let separator = OnnxStemSeparator(inference: Self.halfMixInference)
        let vocalsOut = tempDir.appendingPathComponent("voc.m4a")
        let accOut = tempDir.appendingPathComponent("acc.m4a")
        _ = try separator.separate(inputURL: input, vocalsOut: vocalsOut, accompanimentOut: accOut)
        XCTAssertEqual(Double(try decodeMono(vocalsOut).count), 3 * 44_100, accuracy: 4096)
        XCTAssertEqual(Double(try decodeMono(accOut).count), 3 * 44_100, accuracy: 4096)
    }

    /// A failing model window must not leave half-written stem files behind.
    func testFailureCleansUpOutputs() throws {
        let input = try writeInputFile(name: "in.caf", seconds: 5)
        let separator = OnnxStemSeparator(inference: { _ in
            throw StemSeparationError.inference("boom")
        })
        let vocalsOut = tempDir.appendingPathComponent("voc.m4a")
        let accOut = tempDir.appendingPathComponent("acc.m4a")
        XCTAssertThrowsError(try separator.separate(inputURL: input, vocalsOut: vocalsOut, accompanimentOut: accOut))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vocalsOut.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: accOut.path))
    }

    /// The device-crash regression test: separating a long (25 min) file must not grow the
    /// process footprint by more than ~200 MB. The pre-streaming implementation held ~7
    /// full-length buffers (>1 GB here) and jetsammed real phones.
    func testLongFileBoundedMemory() throws {
        let input = try writeInputFile(name: "long.caf", seconds: 25 * 60)
        let separator = OnnxStemSeparator(inference: Self.halfMixInference)
        let vocalsOut = tempDir.appendingPathComponent("voc.m4a")
        let accOut = tempDir.appendingPathComponent("acc.m4a")

        let before = Self.physFootprint()
        _ = try separator.separate(inputURL: input, vocalsOut: vocalsOut, accompanimentOut: accOut)
        let after = Self.physFootprint()
        let growthMB = Double(after - before) / 1_048_576
        XCTAssertLessThan(growthMB, 200, "streaming separation should stay O(segment) in memory")
        XCTAssertGreaterThan(try decodeMono(vocalsOut).count, 20 * 60 * 44_100)
    }

    private static func physFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
}
