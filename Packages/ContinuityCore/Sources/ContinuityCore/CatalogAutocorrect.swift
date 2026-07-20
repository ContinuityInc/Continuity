import Foundation

/// Autocorrect/suggestion engine for the in-app music-search keyboard, tuned to the catalog
/// being searched rather than general English: the vocabulary is *learned* from catalog
/// results (song titles, artists, album names), so "weeknd", "beyonce" or "sza" are first-class
/// words instead of typos. Pure Swift (no UIKit) so it unit-tests on Linux CI.
///
/// Two operations, both word-level:
/// - `suggestions(for:)` ranks likely intended words for the partial word being typed
///   (prefix completions first, then close misspellings) — feeds the suggestion bar.
/// - `correction(for:)` returns a replacement only when it is *confidently* wrong: the typed
///   word is unknown and exactly one edit away from a known word — applied on space, like a
///   conventional keyboard autocorrect, but against the music vocabulary.
public struct CatalogAutocorrect: Sendable {

    /// Learned vocabulary: lowercase word → accumulated weight (frequency across learned
    /// phrases, so words from many catalog hits outrank one-off matches).
    private var vocabulary: [String: Int] = [:]

    public init() {}

    /// Number of distinct words learned so far.
    public var wordCount: Int { vocabulary.count }

    // MARK: Learning

    /// Tokenizes catalog phrases (titles/artists/albums) into words and folds them into the
    /// vocabulary. Weight lets callers boost trusted sources (e.g. the user's own library).
    public mutating func learn(phrases: [String], weight: Int = 1) {
        for phrase in phrases {
            for word in Self.words(in: phrase) {
                vocabulary[word, default: 0] += weight
            }
        }
    }

    /// Lowercased alphanumeric word split — apostrophes survive ("don't"), everything else
    /// separates. Single characters are dropped (they'd match everything at distance 1).
    static func words(in phrase: String) -> [String] {
        var words: [String] = []
        var current = ""
        for scalar in phrase.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "'" {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.filter { $0.count > 1 }
    }

    // MARK: Suggestions

    /// Ranked candidates for the word being typed: known prefix completions first (what the
    /// user is most likely mid-way through), then close misspelling repairs; within a tier,
    /// higher catalog frequency wins. The typed word itself is never suggested.
    public func suggestions(for partial: String, limit: Int = 3) -> [String] {
        let typed = partial.lowercased()
        guard typed.count >= 2, limit > 0 else { return [] }

        var scored: [(word: String, tier: Int, weight: Int)] = []
        let maxDistance = typed.count <= 4 ? 1 : 2
        for (word, weight) in vocabulary where word != typed {
            if word.hasPrefix(typed) {
                scored.append((word, 0, weight))
            } else if abs(word.count - typed.count) <= maxDistance,
                      Self.editDistance(word, typed, limit: maxDistance) <= maxDistance {
                scored.append((word, 1, weight))
            }
        }
        return scored
            .sorted { ($0.tier, -$0.weight, $0.word) < ($1.tier, -$1.weight, $1.word) }
            .prefix(limit)
            .map(\.word)
    }

    /// The confident space-bar replacement for a finished word, or nil to leave it alone.
    /// Fires only when the word is NOT in the vocabulary and a single-edit repair exists —
    /// known words (however weird; this is music) must never be "corrected".
    public func correction(for word: String) -> String? {
        let typed = word.lowercased()
        guard typed.count >= 3, vocabulary[typed] == nil else { return nil }
        return vocabulary
            .filter { abs($0.key.count - typed.count) <= 1 && Self.editDistance($0.key, typed, limit: 1) <= 1 }
            .max { ($0.value, $1.key) < ($1.value, $0.key) }?  // heaviest wins; ties break alphabetically
            .key
    }

    // MARK: Edit distance

    /// Levenshtein distance with an early-out bound: returns `limit + 1` as soon as the
    /// distance provably exceeds `limit` (the callers only care about "≤ limit").
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let s = Array(a.unicodeScalars), t = Array(b.unicodeScalars)
        if abs(s.count - t.count) > limit { return limit + 1 }
        var previous = Array(0...t.count)
        var current = [Int](repeating: 0, count: t.count + 1)
        for i in 1...max(s.count, 1) where !s.isEmpty {
            current[0] = i
            var rowMin = i
            for j in 1...max(t.count, 1) where !t.isEmpty {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMin = min(rowMin, current[j])
            }
            if rowMin > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return s.isEmpty ? t.count : previous[t.count]
    }
}
