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
///
/// Both run a bounded Levenshtein against the WHOLE vocabulary, and `suggestions` runs on every
/// keystroke — with the user's library seeded in, that vocabulary is thousands of words. So the
/// per-word cost is kept allocation-free: each word's unicode scalars and character count are
/// derived once, when it's learned, and the distance matrix rows are allocated once per query
/// and reused across every candidate.
public struct CatalogAutocorrect: Sendable {

    /// One learned word: the text, the scalars and length the matcher needs (precomputed), and
    /// its accumulated weight (frequency across learned phrases, so words from many catalog
    /// hits outrank one-off matches).
    private struct Entry: Sendable {
        let word: String
        let scalars: [Unicode.Scalar]
        let characterCount: Int
        var weight: Int
    }

    /// Learned vocabulary, in first-seen order.
    private var entries: [Entry] = []
    /// Position of each word in `entries`, so re-learning a known word is a weight bump.
    private var indexByWord: [String: Int] = [:]

    public init() {}

    /// Number of distinct words learned so far.
    public var wordCount: Int { entries.count }

    // MARK: Learning

    /// Tokenizes catalog phrases (titles/artists/albums) into words and folds them into the
    /// vocabulary. Weight lets callers boost trusted sources (e.g. the user's own library).
    public mutating func learn(phrases: [String], weight: Int = 1) {
        for phrase in phrases {
            for word in Self.words(in: phrase) {
                if let index = indexByWord[word] {
                    entries[index].weight += weight
                } else {
                    indexByWord[word] = entries.count
                    entries.append(Entry(
                        word: word,
                        scalars: Array(word.unicodeScalars),
                        characterCount: word.count,
                        weight: weight
                    ))
                }
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

        let typedScalars = Array(typed.unicodeScalars)
        var previous = [Int](repeating: 0, count: typedScalars.count + 1)
        var current = previous

        var scored: [(word: String, tier: Int, weight: Int)] = []
        let maxDistance = typed.count <= 4 ? 1 : 2
        for entry in entries where entry.word != typed {
            if entry.word.hasPrefix(typed) {
                scored.append((entry.word, 0, entry.weight))
            } else if abs(entry.characterCount - typed.count) <= maxDistance,
                      Self.editDistance(entry.scalars, typedScalars, limit: maxDistance,
                                        previous: &previous, current: &current) <= maxDistance {
                scored.append((entry.word, 1, entry.weight))
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
        guard typed.count >= 3, indexByWord[typed] == nil else { return nil }

        let typedScalars = Array(typed.unicodeScalars)
        var previous = [Int](repeating: 0, count: typedScalars.count + 1)
        var current = previous

        // Heaviest wins; ties break alphabetically.
        var best: (word: String, weight: Int)?
        for entry in entries where abs(entry.characterCount - typed.count) <= 1 {
            guard Self.editDistance(entry.scalars, typedScalars, limit: 1,
                                    previous: &previous, current: &current) <= 1 else { continue }
            if let incumbent = best,
               entry.weight < incumbent.weight
                || (entry.weight == incumbent.weight && entry.word > incumbent.word) {
                continue
            }
            best = (entry.word, entry.weight)
        }
        return best?.word
    }

    // MARK: Edit distance

    /// Levenshtein distance with an early-out bound: returns `limit + 1` as soon as the
    /// distance provably exceeds `limit` (the callers only care about "≤ limit").
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let s = Array(a.unicodeScalars), t = Array(b.unicodeScalars)
        var previous = [Int](repeating: 0, count: t.count + 1)
        var current = previous
        return editDistance(s, t, limit: limit, previous: &previous, current: &current)
    }

    /// Scanning variant: takes pre-derived scalars and caller-owned matrix rows, so a scan over
    /// thousands of vocabulary words allocates nothing per word. `previous` and `current` must
    /// each have at least `t.count + 1` elements; their contents on entry are irrelevant.
    static func editDistance(_ s: [Unicode.Scalar], _ t: [Unicode.Scalar], limit: Int,
                             previous: inout [Int], current: inout [Int]) -> Int {
        if abs(s.count - t.count) > limit { return limit + 1 }
        for j in 0...t.count { previous[j] = j }
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
