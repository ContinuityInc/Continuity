import Foundation

/// Small helpers for navigating the loosely-typed `[String: Any]` trees that `JSONSerialization`
/// produces from scraped pages (YouTube `ytInitialData`, Spotify `__NEXT_DATA__`). Kept internal
/// and shared so each scraper doesn't re-implement the same tree-walking.
enum JSONNav {

    /// Follows a chain of dictionary keys, returning the dictionary at the end (or nil).
    static func dict(_ node: Any?, _ keys: [String]) -> [String: Any]? {
        var current = node
        for key in keys { current = (current as? [String: Any])?[key] }
        return current as? [String: Any]
    }

    /// Follows a chain of dictionary keys, returning the array at the end (or nil).
    static func array(_ node: Any?, _ keys: [String]) -> [Any]? {
        var current = node
        for key in keys { current = (current as? [String: Any])?[key] }
        return current as? [Any]
    }

    /// Follows a chain of dictionary keys, returning the string at the end (or nil).
    static func string(_ node: Any?, _ keys: [String]) -> String? {
        var current = node
        for key in keys { current = (current as? [String: Any])?[key] }
        return current as? String
    }

    /// First dictionary anywhere in the tree that itself contains `key`.
    static func firstDictContaining(_ node: Any, key: String) -> [String: Any]? {
        if let dict = node as? [String: Any] {
            if dict[key] != nil { return dict }
            for value in dict.values {
                if let found = firstDictContaining(value, key: key) { return found }
            }
        } else if let array = node as? [Any] {
            for value in array {
                if let found = firstDictContaining(value, key: key) { return found }
            }
        }
        return nil
    }

    /// Returns the balanced `open … close` literal that follows `marker` in `text` (e.g. the
    /// `[ … ]` array after `window.__sc_hydration =`), tracking string literals so brackets
    /// inside values don't end the scan early. Nil if the marker or a balanced literal is missing.
    static func balancedLiteral(in text: String, afterMarker marker: String, open: Character, close: Character) -> String? {
        guard let markerRange = text.range(of: marker),
              let start = text[markerRange.upperBound...].firstIndex(of: open) else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == open {
                depth += 1
            } else if c == close {
                depth -= 1
                if depth == 0 { return String(text[start...i]) }
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// Depth-first pre-order visit of every dictionary node (arrays traversed in order).
    static func walk(_ node: Any, _ visit: ([String: Any]) -> Void) {
        if let dict = node as? [String: Any] {
            visit(dict)
            for value in dict.values { walk(value, visit) }
        } else if let array = node as? [Any] {
            for value in array { walk(value, visit) }
        }
    }
}
