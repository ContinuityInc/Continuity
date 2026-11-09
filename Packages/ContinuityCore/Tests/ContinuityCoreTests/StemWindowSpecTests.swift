import XCTest
@testable import ContinuityCore

final class StemWindowSpecTests: XCTestCase {
    func testSegmentMatchesDemucs78s() {
        XCTAssertEqual(StemWindowSpec.segmentFrames, 343_980)
        let seconds = Double(StemWindowSpec.segmentFrames) / StemWindowSpec.sampleRate
        XCTAssertEqual(seconds, 7.8, accuracy: 1e-9)
    }

    func testOverlapIsQuarterSegment() {
        XCTAssertEqual(StemWindowSpec.overlapFrames, StemWindowSpec.segmentFrames / 4)
        XCTAssertEqual(StemWindowSpec.strideFrames, StemWindowSpec.segmentFrames - StemWindowSpec.overlapFrames)
        XCTAssertEqual(StemWindowSpec.overlapFraction, 0.25, accuracy: 1e-12)
    }

    func testVocalsIndexInSourceOrder() {
        XCTAssertEqual(StemWindowSpec.sourceCount, 4)
        XCTAssertEqual(StemWindowSpec.vocalsSourceIndex, 3)
        XCTAssertEqual(StemWindowSpec.mixInputName, "mix")
        XCTAssertEqual(StemWindowSpec.stemsOutputName, "stems")
    }
}
