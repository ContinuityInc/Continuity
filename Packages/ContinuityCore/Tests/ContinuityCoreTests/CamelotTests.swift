import XCTest
@testable import ContinuityCore

final class CamelotTests: XCTestCase {

    func testCodeFormatting() {
        XCTAssertEqual(Camelot(number: 8, side: .b).code, "8B")
        XCTAssertEqual(Camelot(number: 12, side: .a).code, "12A")
    }

    func testIdentityIsCompatible() {
        let c = Camelot(number: 8, side: .a)
        XCTAssertTrue(c.isCompatible(with: c))
    }

    func testRelativeMajorMinorIsCompatible() {
        // Same number, different side (e.g. 8A <-> 8B).
        XCTAssertTrue(Camelot(number: 8, side: .a).isCompatible(with: Camelot(number: 8, side: .b)))
    }

    func testAdjacentHourSameSideIsCompatible() {
        XCTAssertTrue(Camelot(number: 8, side: .a).isCompatible(with: Camelot(number: 9, side: .a)))
        XCTAssertTrue(Camelot(number: 8, side: .a).isCompatible(with: Camelot(number: 7, side: .a)))
    }

    func testWheelWrapsAround() {
        // 12A is adjacent to 1A across the wrap.
        XCTAssertTrue(Camelot(number: 12, side: .a).isCompatible(with: Camelot(number: 1, side: .a)))
        XCTAssertEqual(Camelot(number: 12, side: .a).hourDistance(to: Camelot(number: 1, side: .a)), 1)
    }

    func testIncompatiblePairs() {
        // Two hours apart, same side: not compatible.
        XCTAssertFalse(Camelot(number: 8, side: .a).isCompatible(with: Camelot(number: 10, side: .a)))
        // Adjacent hour but opposite side: not compatible.
        XCTAssertFalse(Camelot(number: 8, side: .a).isCompatible(with: Camelot(number: 9, side: .b)))
    }

    func testCompatibleNeighboursHasFourEntries() {
        let n = Camelot(number: 8, side: .a).compatibleNeighbours
        XCTAssertEqual(n.count, 4) // self, relative, +1, -1
        XCTAssertTrue(n.contains(Camelot(number: 8, side: .b)))
        XCTAssertTrue(n.contains(Camelot(number: 9, side: .a)))
        XCTAssertTrue(n.contains(Camelot(number: 7, side: .a)))
    }

    func testKeyToCamelotMapping() {
        XCTAssertEqual(MusicalKey.aMinor.camelot, Camelot(number: 8, side: .a))
        XCTAssertEqual(MusicalKey.cMajor.camelot, Camelot(number: 8, side: .b))
        XCTAssertEqual(MusicalKey.eMinor.camelot, Camelot(number: 9, side: .a))
        // C major and A minor are relative keys -> harmonically compatible.
        XCTAssertTrue(MusicalKey.cMajor.camelot.isCompatible(with: MusicalKey.aMinor.camelot))
    }
}
