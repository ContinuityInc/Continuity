import XCTest
@testable import ContinuityCore

final class StemQualityMetricsTests: XCTestCase {
    func testSiSDRIdenticalIsHigh() throws {
        let ref = (0..<1_024).map { Float(sin(Double($0) * 0.01)) }
        let score = try XCTUnwrap(StemQualityMetrics.siSDR(estimate: ref, reference: ref))
        XCTAssertGreaterThan(score, 80)
    }

    func testSiSDRScaleInvariant() throws {
        let ref = (0..<2_048).map { Float(sin(Double($0) * 0.02)) }
        let scaled = ref.map { $0 * 2.5 }
        let score = try XCTUnwrap(StemQualityMetrics.siSDR(estimate: scaled, reference: ref))
        XCTAssertGreaterThan(score, 80)
    }

    func testSiSDRNoiseLowersScore() throws {
        let ref = (0..<2_048).map { Float(sin(Double($0) * 0.03)) }
        let noisy = ref.enumerated().map { i, v in v + (i % 2 == 0 ? 0.2 : -0.2) }
        let clean = try XCTUnwrap(StemQualityMetrics.siSDR(estimate: ref, reference: ref))
        let dirty = try XCTUnwrap(StemQualityMetrics.siSDR(estimate: noisy, reference: ref))
        XCTAssertGreaterThan(clean, dirty)
        XCTAssertLessThan(dirty, 40)
    }

    func testMeanSiSDRPlanar() throws {
        let frames = 512
        var planar = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            planar[i] = Float(i) * 0.001
            planar[frames + i] = Float(i) * -0.001
        }
        let score = try XCTUnwrap(
            StemQualityMetrics.meanSiSDR(estimatePlanar: planar, referencePlanar: planar, frames: frames))
        XCTAssertGreaterThan(score, 80)
    }

    func testEnergyRatioHalfPowerIsMinusThree() throws {
        let mix = [Float](repeating: 1, count: 100)
        let half = [Float](repeating: 0.5, count: 100) // energy ratio 0.25 → -6 dB
        let ratio = try XCTUnwrap(StemQualityMetrics.energyRatioDB(numerator: half, denominator: mix))
        XCTAssertEqual(ratio, -6, accuracy: 1e-4)
    }

    func testMaxAbsDiff() {
        XCTAssertEqual(StemQualityMetrics.maxAbsDiff([1, 2, 3], [1, 2.5, 3]), 0.5)
        XCTAssertNil(StemQualityMetrics.maxAbsDiff([1], [1, 2]))
    }
}
