import XCTest
@testable import ContinuityCore

final class CrossfadeCurvesTests: XCTestCase {

    func testEndpointsAreFullySwapped() {
        for curve in CrossfadeCurve.allCases {
            let start = curve.gains(at: 0)
            let end = curve.gains(at: 1)
            XCTAssertEqual(start.outgoing, 1, accuracy: 1e-9, "\(curve) should start fully on outgoing")
            XCTAssertEqual(start.incoming, 0, accuracy: 1e-9)
            XCTAssertEqual(end.outgoing, 0, accuracy: 1e-9, "\(curve) should end fully on incoming")
            XCTAssertEqual(end.incoming, 1, accuracy: 1e-9)
        }
    }

    func testProgressIsClamped() {
        let curve = CrossfadeCurve.equalPower
        XCTAssertEqual(curve.gains(at: -5), curve.gains(at: 0))
        XCTAssertEqual(curve.gains(at: 5), curve.gains(at: 1))
    }

    func testEqualPowerHoldsConstantPower() {
        // out^2 + in^2 should stay ~1 across the whole blend.
        let curve = CrossfadeCurve.equalPower
        for i in 0...20 {
            let t = Double(i) / 20
            let g = curve.gains(at: t)
            let power = g.outgoing * g.outgoing + g.incoming * g.incoming
            XCTAssertEqual(power, 1, accuracy: 1e-9, "power should be flat at t=\(t)")
        }
    }

    func testLinearMidpointDipsBelowUnityPower() {
        // The whole reason equal-power exists: linear sags in the middle.
        let g = CrossfadeCurve.linear.gains(at: 0.5)
        let power = g.outgoing * g.outgoing + g.incoming * g.incoming
        XCTAssertLessThan(power, 1)
        XCTAssertEqual(power, 0.5, accuracy: 1e-9)
    }

    func testConstantPowerFlag() {
        XCTAssertFalse(CrossfadeCurve.linear.isConstantPower)
        XCTAssertTrue(CrossfadeCurve.equalPower.isConstantPower)
        XCTAssertTrue(CrossfadeCurve.smooth.isConstantPower)
    }
}
