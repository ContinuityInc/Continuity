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

    func testParse() {
        XCTAssertEqual(Camelot.parse("8B"), Camelot(number: 8, side: .b))
        XCTAssertEqual(Camelot.parse("12a"), Camelot(number: 12, side: .a))
        XCTAssertEqual(Camelot.parse(" 1A "), Camelot(number: 1, side: .a))
        XCTAssertNil(Camelot.parse("13B"))   // hour out of range
        XCTAssertNil(Camelot.parse("8C"))    // bad side
        XCTAssertNil(Camelot.parse("B8"))
        XCTAssertNil(Camelot.parse(""))
    }

    func testTransposition() {
        // C major (8B) up a semitone is C#/Db major (3B): +7 hours on the wheel.
        XCTAssertEqual(Camelot(number: 8, side: .b).transposed(bySemitones: 1), Camelot(number: 3, side: .b))
        // Down a semitone from C major is B major (1B).
        XCTAssertEqual(Camelot(number: 8, side: .b).transposed(bySemitones: -1), Camelot(number: 1, side: .b))
        // A full octave (12 semitones) is the identity.
        XCTAssertEqual(Camelot(number: 5, side: .a).transposed(bySemitones: 12), Camelot(number: 5, side: .a))
    }

    func testPitchShiftPrefersNoShift() {
        // Already compatible (relative / neighbour) -> shift 0.
        XCTAssertEqual(HarmonicMix.pitchShiftSemitones(incoming: Camelot.parse("8B")!, outgoing: Camelot.parse("8A")!), 0)
        XCTAssertEqual(HarmonicMix.pitchShiftSemitones(incoming: Camelot.parse("9B")!, outgoing: Camelot.parse("8B")!), 0)
    }

    func testPitchShiftFindsSemitoneNudge() {
        // C major (8B) into D major (10B): +1 -> 3B (no), -1 -> 1B (no) -> nil (too far to nudge).
        XCTAssertNil(HarmonicMix.pitchShiftSemitones(incoming: Camelot.parse("8B")!, outgoing: Camelot.parse("10B")!))
        // C major (8B) into E major (12B): +1 -> 3B (no), -1 -> 1B, a neighbour of 12B -> -1.
        XCTAssertEqual(HarmonicMix.pitchShiftSemitones(incoming: Camelot.parse("8B")!, outgoing: Camelot.parse("12B")!), -1)
        // F major (7B) into F# major (2B): +1 semitone lands exactly on 2B -> +1.
        XCTAssertEqual(HarmonicMix.pitchShiftSemitones(incoming: Camelot.parse("7B")!, outgoing: Camelot.parse("2B")!), 1)
    }
}
