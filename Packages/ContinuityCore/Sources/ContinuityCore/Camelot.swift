import Foundation

/// A position on the Camelot wheel (a.k.a. the "key wheel" used for harmonic mixing).
///
/// The wheel has 12 numbered hours (1...12). Letter `A` is the minor side, `B` is the
/// major side. Two tracks mix harmonically when their Camelot codes are "adjacent":
///   - identical codes, or
///   - same number, different letter (relative major/minor), or
///   - same letter, number ±1 (mod 12, neighbouring hour).
public struct Camelot: Equatable, Hashable, Sendable, Codable {
    public enum Side: String, Sendable, Codable { case a = "A", b = "B" }

    /// Hour on the wheel, 1...12.
    public let number: Int
    /// Minor (`A`) or major (`B`) side.
    public let side: Side

    public init(number: Int, side: Side) {
        precondition((1...12).contains(number), "Camelot number must be 1...12")
        self.number = number
        self.side = side
    }

    /// e.g. "8A", "12B".
    public var code: String { "\(number)\(side.rawValue)" }

    /// Distance (number of wheel hops) to another code along the same letter ring,
    /// taking the shorter direction around the 12-hour wheel.
    public func hourDistance(to other: Camelot) -> Int {
        let raw = abs(number - other.number)
        return min(raw, 12 - raw)
    }

    /// Whether mixing into `other` is harmonically compatible under the standard rules.
    public func isCompatible(with other: Camelot) -> Bool {
        if self == other { return true }
        if number == other.number { return true }                 // relative major/minor
        if side == other.side && hourDistance(to: other) == 1 { return true } // ±1 hour
        return false
    }

    /// All codes considered harmonically compatible with this one (including itself).
    public var compatibleNeighbours: Set<Camelot> {
        var result: Set<Camelot> = [self]
        let other: Side = side == .a ? .b : .a
        result.insert(Camelot(number: number, side: other))
        result.insert(Camelot(number: wrap(number + 1), side: side))
        result.insert(Camelot(number: wrap(number - 1), side: side))
        return result
    }

    private func wrap(_ n: Int) -> Int {
        // Map any integer onto 1...12.
        let m = ((n - 1) % 12 + 12) % 12
        return m + 1
    }

    /// Parses a Camelot code string (e.g. "8B", "12a"). Returns nil for anything malformed.
    public static func parse(_ code: String) -> Camelot? {
        let trimmed = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard let letter = trimmed.last, let side = Side(rawValue: String(letter)),
              let number = Int(trimmed.dropLast()), (1...12).contains(number) else {
            return nil
        }
        return Camelot(number: number, side: side)
    }

    /// The key this becomes when the audio is pitch-shifted by `semitones`.
    /// One semitone up moves the wheel +7 hours (circle of fifths); the mode (side) is unchanged.
    public func transposed(bySemitones semitones: Int) -> Camelot {
        Camelot(number: wrap(number + 7 * semitones), side: side)
    }
}

/// Decides how to make two keys harmonically compatible for the flagship blend.
public enum HarmonicMix {
    /// The pitch shift (whole semitones) to apply to the **incoming** track so its key becomes
    /// Camelot-compatible with the outgoing key. Prefers no shift, then ±1 semitone (±100 cents —
    /// subtle enough to pass unnoticed; larger shifts sound wrong, so incompatible-beyond-±1 pairs
    /// return nil and the caller falls back to an unshifted blend).
    public static func pitchShiftSemitones(incoming: Camelot, outgoing: Camelot) -> Int? {
        for shift in [0, 1, -1] where incoming.transposed(bySemitones: shift).isCompatible(with: outgoing) {
            return shift
        }
        return nil
    }
}

/// The 24 musical keys, used to derive a Camelot code from detected key estimates.
public enum MusicalKey: String, CaseIterable, Sendable, Codable {
    case cMajor, gMajor, dMajor, aMajor, eMajor, bMajor, fSharpMajor,
         dFlatMajor, aFlatMajor, eFlatMajor, bFlatMajor, fMajor
    case aMinor, eMinor, bMinor, fSharpMinor, cSharpMinor, gSharpMinor, dSharpMinor,
         bFlatMinor, fMinor, cMinor, gMinor, dMinor

    /// The Camelot code for this key (the canonical wheel mapping).
    public var camelot: Camelot {
        switch self {
        case .aFlatMajor:   return Camelot(number: 4, side: .b)
        case .eFlatMajor:   return Camelot(number: 5, side: .b)
        case .bFlatMajor:   return Camelot(number: 6, side: .b)
        case .fMajor:       return Camelot(number: 7, side: .b)
        case .cMajor:       return Camelot(number: 8, side: .b)
        case .gMajor:       return Camelot(number: 9, side: .b)
        case .dMajor:       return Camelot(number: 10, side: .b)
        case .aMajor:       return Camelot(number: 11, side: .b)
        case .eMajor:       return Camelot(number: 12, side: .b)
        case .bMajor:       return Camelot(number: 1, side: .b)
        case .fSharpMajor:  return Camelot(number: 2, side: .b)
        case .dFlatMajor:   return Camelot(number: 3, side: .b)
        case .fMinor:       return Camelot(number: 4, side: .a)
        case .cMinor:       return Camelot(number: 5, side: .a)
        case .gMinor:       return Camelot(number: 6, side: .a)
        case .dMinor:       return Camelot(number: 7, side: .a)
        case .aMinor:       return Camelot(number: 8, side: .a)
        case .eMinor:       return Camelot(number: 9, side: .a)
        case .bMinor:       return Camelot(number: 10, side: .a)
        case .fSharpMinor:  return Camelot(number: 11, side: .a)
        case .cSharpMinor:  return Camelot(number: 12, side: .a)
        case .gSharpMinor:  return Camelot(number: 1, side: .a)
        case .dSharpMinor:  return Camelot(number: 2, side: .a)
        case .bFlatMinor:   return Camelot(number: 3, side: .a)
        }
    }
}
