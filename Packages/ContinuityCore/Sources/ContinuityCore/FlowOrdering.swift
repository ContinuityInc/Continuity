import Foundation

/// Minimal per-track analysis needed to order a queue for Flow mode. `camelotCode` is the
/// raw detected string (e.g. "8A"); it's kept as a string so callers don't need to depend
/// on `Camelot` — malformed codes simply count as "key unknown".
public struct FlowItem: Sendable, Equatable {
    public let id: UUID
    public let bpm: Double?
    public let camelotCode: String?
    public init(id: UUID, bpm: Double?, camelotCode: String?) {
        self.id = id
        self.bpm = bpm
        self.camelotCode = camelotCode
    }
}

/// Orders a set of analyzed tracks into a DJ-style sequence where consecutive tracks are
/// harmonically and tempo-compatible. Greedy nearest-neighbour rather than an exact tour:
/// queues are small and users reorder anyway, so a predictable O(n²) pass beats TSP machinery.
public enum FlowOrdering {

    /// Greedy nearest-compatible ordering: starts at startID (if present in items, else the first
    /// analyzed item), then repeatedly picks the unvisited item with the lowest transition cost.
    /// Returns every input id exactly once. Items missing both bpm and key sink to the end,
    /// preserving their relative input order.
    public static func order(_ items: [FlowItem], startingAt startID: UUID?) -> [UUID] {
        guard !items.isEmpty else { return [] }

        // Pre-resolve keys once; a malformed code is the same as no key.
        let nodes = items.map { item in
            Node(item: item, key: item.camelotCode.flatMap(Camelot.parse))
        }

        // Unanalyzed tracks (no bpm AND no key) carry no ordering signal — greedy over them
        // would just shuffle by penalty ties, so sink them to the end in input order instead.
        var analyzed: [Int] = []
        var unanalyzed: [Int] = []
        for (i, node) in nodes.enumerated() {
            if node.item.bpm == nil && node.key == nil {
                unanalyzed.append(i)
            } else {
                analyzed.append(i)
            }
        }

        var result: [UUID] = []
        result.reserveCapacity(items.count)

        // Honour an explicit start even if it's unanalyzed — the user picked it.
        var currentIndex: Int?
        if let startID, let start = nodes.firstIndex(where: { $0.item.id == startID }) {
            currentIndex = start
            analyzed.removeAll { $0 == start }
            unanalyzed.removeAll { $0 == start }
            result.append(startID)
        } else if let first = analyzed.first {
            currentIndex = first
            analyzed.removeFirst()
            result.append(nodes[first].item.id)
        }

        // Greedy walk: strict `<` keeps the earliest input index on cost ties → deterministic.
        while let current = currentIndex, !analyzed.isEmpty {
            var bestPos = 0
            var bestCost = Double.infinity
            for (pos, candidate) in analyzed.enumerated() {
                let cost = transitionCost(from: nodes[current], to: nodes[candidate])
                if cost < bestCost {
                    bestCost = cost
                    bestPos = pos
                }
            }
            let next = analyzed.remove(at: bestPos)
            result.append(nodes[next].item.id)
            currentIndex = next
        }

        for i in unanalyzed {
            result.append(nodes[i].item.id)
        }
        return result
    }

    private struct Node {
        let item: FlowItem
        let key: Camelot?
    }

    /// One "camelot hop" (letter swap or ±1 hour — the standard compatible moves) is the
    /// unit of cost; everything else is scaled relative to it.
    private static let hopCost = 1.0
    /// Charged once per comparison when either side is unknown. Moderate: worse than any
    /// compatible move, better than a far wheel jump, so unknowns slot next to anything
    /// without dominating.
    private static let unknownKeyPenalty = 2.5
    private static let unknownBPMPenalty = 2.5
    /// abs(log ratio) → hop units, calibrated so ~8% tempo distance (the audible time-stretch
    /// ceiling in BeatMath) costs the same as one camelot hop.
    private static let tempoScale = hopCost / log(1.08)

    /// Transition cost = camelot distance + tempo distance, in hop units.
    ///
    /// Key component: 0 for the same key; 1 hop for the three compatible neighbours
    /// (relative major/minor, ±1 hour); beyond that, min hops around the 12-hour wheel
    /// plus 1 for a needed letter swap — escalating smoothly with harmonic distance.
    ///
    /// Tempo component: abs(log(bpmA/bpmB)), taking the best of {ratio, ratio·2, ratio/2}
    /// so half/double-time pairs (170 vs 85) compare as equal tempo, matching how the
    /// playback engine beatmatches (BeatMath.bestTempoRatio).
    private static func transitionCost(from: Node, to: Node) -> Double {
        var cost = 0.0

        switch (from.key, to.key) {
        case let (a?, b?):
            if a == b {
                cost += 0
            } else if a.isCompatible(with: b) {
                cost += hopCost
            } else {
                let swap = a.side == b.side ? 0.0 : 1.0
                cost += (Double(a.hourDistance(to: b)) + swap) * hopCost
            }
        default:
            cost += unknownKeyPenalty
        }

        switch (from.item.bpm, to.item.bpm) {
        case let (a?, b?) where a > 0 && b > 0:
            let ratio = a / b
            let best = [ratio, ratio * 2, ratio / 2].map { abs(log($0)) }.min()!
            cost += best * tempoScale
        default:
            cost += unknownBPMPenalty
        }

        return cost
    }
}
