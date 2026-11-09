import XCTest
@testable import ContinuityCore

final class OverlapAddTests: XCTestCase {

    /// Reference batch implementation mirroring the pre-streaming StemSeparator math:
    /// accumulate window-weighted output over the whole signal, then normalize where weight > 0.
    private func batchOverlapAdd(signal: [Float], segment: Int, overlap: Int,
                                 transform: (Float) -> Float) -> [Float] {
        let frames = signal.count
        let stride = segment - overlap
        let window = StreamingOverlapAdd.transitionWindow(segment: segment, fade: overlap)
        var out = [Float](repeating: 0, count: frames)
        var weight = [Float](repeating: 0, count: frames)
        var start = 0
        while start < frames {
            let length = min(segment, frames - start)
            for i in 0..<length {
                out[start + i] += transform(signal[start + i]) * window[i]
                weight[start + i] += window[i]
            }
            start += stride
        }
        for i in 0..<frames where weight[i] > 0 { out[i] /= weight[i] }
        return out
    }

    /// Streams the same signal through StreamingOverlapAdd, draining after each window exactly as
    /// the separator does (finalized boundary = next window start).
    private func streamOverlapAdd(signal: [Float], segment: Int, overlap: Int,
                                  transform: (Float) -> Float) -> [Float] {
        let frames = signal.count
        let ola = StreamingOverlapAdd(channels: 1, segment: segment, overlap: overlap)
        var out = [Float]()
        var start = 0
        while start < frames {
            let length = min(segment, frames - start)
            ola.add(start: start, length: length) { _, i in transform(signal[start + i]) }
            start += ola.stride
            out.append(contentsOf: ola.drain(upTo: min(start, frames))[0])
        }
        return out
    }

    private func assertParity(frames: Int, segment: Int, overlap: Int,
                              file: StaticString = #filePath, line: UInt = #line) {
        let signal = (0..<frames).map { Float(sin(Double($0) * 0.37)) }
        let transform: (Float) -> Float = { $0 * 0.5 + 0.1 }
        let batch = batchOverlapAdd(signal: signal, segment: segment, overlap: overlap, transform: transform)
        let streamed = streamOverlapAdd(signal: signal, segment: segment, overlap: overlap, transform: transform)
        XCTAssertEqual(streamed.count, batch.count, file: file, line: line)
        for i in 0..<batch.count {
            XCTAssertEqual(streamed[i], batch[i], accuracy: 1e-6,
                           "mismatch at frame \(i)", file: file, line: line)
        }
    }

    func testShorterThanOneSegment() { assertParity(frames: 37, segment: 64, overlap: 16) }
    func testExactlyOneSegment() { assertParity(frames: 64, segment: 64, overlap: 16) }
    func testStrideAlignedLength() { assertParity(frames: 48 * 5, segment: 64, overlap: 16) }
    func testUnalignedLongLength() { assertParity(frames: 48 * 7 + 13, segment: 64, overlap: 16) }
    func testSingleFrame() { assertParity(frames: 1, segment: 64, overlap: 16) }
    func testNoOverlap() { assertParity(frames: 200, segment: 64, overlap: 0) }
    func testModelShapedRatio() {
        // Same segment:overlap ratio as HT-Demucs use (overlap = segment / 4).
        assertParity(frames: 2500, segment: 344, overlap: 86)
    }

    func testTransitionWindowMatchesLegacyShape() {
        let w = StreamingOverlapAdd.transitionWindow(segment: 8, fade: 3)
        XCTAssertEqual(w[0], 0)
        XCTAssertEqual(w[1], 0.5)
        XCTAssertEqual(w[2], 1)
        XCTAssertEqual(w[3], 1)
        XCTAssertEqual(w[4], 1)
        XCTAssertEqual(w[5], 1)
        XCTAssertEqual(w[6], 0.5)
        XCTAssertEqual(w[7], 0)
    }

    func testDegenerateFadeIsAllOnes() {
        XCTAssertEqual(StreamingOverlapAdd.transitionWindow(segment: 4, fade: 1), [1, 1, 1, 1])
        XCTAssertEqual(StreamingOverlapAdd.transitionWindow(segment: 4, fade: 3), [1, 1, 1, 1])
    }

    func testMultiChannelIndependence() {
        let ola = StreamingOverlapAdd(channels: 2, segment: 64, overlap: 16)
        ola.add(start: 0, length: 64) { c, i in c == 0 ? Float(i) : Float(-i) }
        let out = ola.drain(upTo: 48)
        XCTAssertEqual(out.count, 2)
        for i in 2..<48 { // skip the zero-weight first sample and fade start
            XCTAssertEqual(out[0][i], -out[1][i], accuracy: 1e-6)
        }
    }
}
