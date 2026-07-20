import Foundation

/// Streaming overlap-add accumulator for fixed-size windowed inference (e.g. stem separation).
///
/// Windows of `segment` frames start at multiples of `stride = segment - overlap`. Because window
/// starts are non-decreasing, every frame before the *next* window's start is final once the
/// current window has been added — so only O(segment + stride) frames of state are ever pending,
/// regardless of stream length. Callers `add` each window's raw model output, then `drain` the
/// finalized, weight-normalized frames and stream them onward (e.g. straight into an encoder).
public final class StreamingOverlapAdd {
    public let channels: Int
    public let segment: Int
    public let overlap: Int
    public var stride: Int { segment - overlap }
    /// The cross-blend window applied to each added segment.
    public let window: [Float]

    /// First frame index still held in internal state (everything before it has been drained).
    private var base = 0
    /// Physical index of frame `base` within `acc`/`weight`. Drains advance this cursor and
    /// compact only once a segment of dead frames accumulates — removeFirst on every drain
    /// memmoved the whole remaining buffer per window.
    private var head = 0
    /// Per-channel weighted accumulation, index i ↔ absolute frame base + i.
    private var acc: [[Float]]
    /// Sum of window weights per frame, shared across channels.
    private var weight: [Float]
    /// Frames covered by state: [base, base + count).
    private var count = 0

    public init(channels: Int, segment: Int, overlap: Int) {
        precondition(channels > 0 && segment > 0 && overlap >= 0 && overlap < segment)
        self.channels = channels
        self.segment = segment
        self.overlap = overlap
        self.window = Self.transitionWindow(segment: segment, fade: overlap)
        self.acc = Array(repeating: [], count: channels)
        self.weight = []
    }

    /// Adds one window's model output starting at absolute frame `start` (window starts must be
    /// non-decreasing across calls, ≥ the last drain point). `length` is the number of valid
    /// frames (< `segment` only for the final, zero-padded window). `sample(channel, i)` returns
    /// the raw output frame `start + i` for `channel`; the blend window is applied here.
    public func add(start: Int, length: Int, sample: (Int, Int) -> Float) {
        precondition(start >= base, "window starts before drained region")
        precondition(length >= 0 && length <= segment)
        let needed = (start - base) + length
        if needed > count {
            let grow = (head + needed) - weight.count
            for c in 0..<channels { acc[c].append(contentsOf: repeatElement(0, count: grow)) }
            weight.append(contentsOf: repeatElement(0, count: grow))
            count = needed
        }
        let offset = head + (start - base)
        for i in 0..<length {
            let w = window[i]
            for c in 0..<channels { acc[c][offset + i] += sample(c, i) * w }
            weight[offset + i] += w
        }
    }

    /// Removes and returns the weight-normalized frames in [current base, `upTo`) — one array per
    /// channel. `upTo` must not exceed the highest frame added. Frames never touched by any
    /// window (zero weight) are returned as 0, matching the batch implementation's `weight > 0`
    /// guard.
    public func drain(upTo: Int) -> [[Float]] {
        precondition(upTo >= base && upTo - base <= count, "drain past accumulated frames")
        let n = upTo - base
        var out = Array(repeating: [Float](repeating: 0, count: n), count: channels)
        for i in 0..<n {
            let w = weight[head + i]
            guard w > 0 else { continue }
            for c in 0..<channels { out[c][i] = acc[c][head + i] / w }
        }
        head += n
        base = upTo
        count -= n
        // Amortized compaction: shed dead frames once a segment's worth piled up.
        if head >= segment {
            for c in 0..<channels { acc[c].removeFirst(head) }
            weight.removeFirst(head)
            head = 0
        }
        return out
    }

    /// Linear fade-in/out window of length `segment`, fading over `fade` samples at each end, so
    /// overlapping chunks cross-blend cleanly under overlap-add normalization.
    public static func transitionWindow(segment: Int, fade: Int) -> [Float] {
        var window = [Float](repeating: 1, count: segment)
        guard fade > 1, fade * 2 <= segment else { return window }
        for i in 0..<fade {
            let g = Float(i) / Float(fade - 1)
            window[i] = g
            window[segment - 1 - i] = g
        }
        return window
    }
}
