import Foundation

/// One `mem[...]` sample captured at a pipeline stage. Pure numbers so Linux CI can format
/// and assert without Darwin / `os_proc_available_memory`.
public struct MemoryBreadcrumbSample: Sendable, Equatable {
    public var label: String
    public var headroomMB: Int?
    public var rssMB: Int?

    public init(label: String, headroomMB: Int? = nil, rssMB: Int? = nil) {
        self.label = label
        self.headroomMB = headroomMB
        self.rssMB = rssMB
    }
}

/// Snapshot for the Diagnostics "stem / playback budget" card — RSS peaks from breadcrumbs,
/// AdaptiveQuality tier, and AVFAudio exception count — so ORT vs Core ML A/Bs compare on
/// the same one-page export.
public struct DiagnosticsBudgetSnapshot: Sendable, Equatable {
    public var qualityTier: String
    public var avfAudioExceptionCount: Int
    public var lastCaughtDescription: String?
    public var stemRequiredStartMB: Int
    public var stemWindowFloorMB: Int
    public var physicalMemoryMB: Int?
    public var currentHeadroomMB: Int?
    public var currentRSSMB: Int?
    public var peakRSSMB: Int?
    public var sessionLoadBeginRSSMB: Int?
    public var sessionLoadReadyRSSMB: Int?
    public var windowPeakRSSMB: Int?
    public var separationDoneRSSMB: Int?
    public var sessionDrainRSSMB: Int?
    public var latestPlaybackHeadroomMB: Int?
    public var latestPlaybackRSSMB: Int?
    public var recentBreadcrumbs: [MemoryBreadcrumbSample]

    public init(
        qualityTier: String,
        avfAudioExceptionCount: Int,
        lastCaughtDescription: String? = nil,
        stemRequiredStartMB: Int,
        stemWindowFloorMB: Int,
        physicalMemoryMB: Int? = nil,
        currentHeadroomMB: Int? = nil,
        currentRSSMB: Int? = nil,
        peakRSSMB: Int? = nil,
        sessionLoadBeginRSSMB: Int? = nil,
        sessionLoadReadyRSSMB: Int? = nil,
        windowPeakRSSMB: Int? = nil,
        separationDoneRSSMB: Int? = nil,
        sessionDrainRSSMB: Int? = nil,
        latestPlaybackHeadroomMB: Int? = nil,
        latestPlaybackRSSMB: Int? = nil,
        recentBreadcrumbs: [MemoryBreadcrumbSample] = []
    ) {
        self.qualityTier = qualityTier
        self.avfAudioExceptionCount = avfAudioExceptionCount
        self.lastCaughtDescription = lastCaughtDescription
        self.stemRequiredStartMB = stemRequiredStartMB
        self.stemWindowFloorMB = stemWindowFloorMB
        self.physicalMemoryMB = physicalMemoryMB
        self.currentHeadroomMB = currentHeadroomMB
        self.currentRSSMB = currentRSSMB
        self.peakRSSMB = peakRSSMB
        self.sessionLoadBeginRSSMB = sessionLoadBeginRSSMB
        self.sessionLoadReadyRSSMB = sessionLoadReadyRSSMB
        self.windowPeakRSSMB = windowPeakRSSMB
        self.separationDoneRSSMB = separationDoneRSSMB
        self.sessionDrainRSSMB = sessionDrainRSSMB
        self.latestPlaybackHeadroomMB = latestPlaybackHeadroomMB
        self.latestPlaybackRSSMB = latestPlaybackRSSMB
        self.recentBreadcrumbs = recentBreadcrumbs
    }
}

/// Process-wide breadcrumb ring + RSS peaks. Fed by Ingest `MemoryFootprint` and Playback's
/// `mem[playback]` heartbeat; ContinuityCore stays Darwin-free so Linux CI owns the math.
public final class MemoryBudgetRecorder: @unchecked Sendable {
    public static let shared = MemoryBudgetRecorder()

    /// Keep enough recent samples for one separation + a few playback heartbeats.
    public static let capacity = 64

    private let lock = NSLock()
    private var samples: [MemoryBreadcrumbSample] = []
    private var peakRSSMB: Int?

    public init() {}

    public func record(_ sample: MemoryBreadcrumbSample) {
        lock.lock()
        defer { lock.unlock() }
        samples.append(sample)
        if samples.count > Self.capacity {
            samples.removeFirst(samples.count - Self.capacity)
        }
        if let rss = sample.rssMB {
            peakRSSMB = max(peakRSSMB ?? rss, rss)
        }
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
        peakRSSMB = nil
    }

    /// Builds a budget snapshot from recorded breadcrumbs plus live tier / exception inputs.
    public func makeSnapshot(
        qualityTier: String,
        avfAudioExceptionCount: Int,
        lastCaughtDescription: String? = nil,
        stemRequiredStartMB: Int,
        stemWindowFloorMB: Int,
        physicalMemoryMB: Int? = nil,
        currentHeadroomMB: Int? = nil,
        currentRSSMB: Int? = nil
    ) -> DiagnosticsBudgetSnapshot {
        lock.lock()
        let copy = samples
        let peak = peakRSSMB
        lock.unlock()
        return Self.snapshot(
            from: copy,
            peakRSSMB: peak,
            qualityTier: qualityTier,
            avfAudioExceptionCount: avfAudioExceptionCount,
            lastCaughtDescription: lastCaughtDescription,
            stemRequiredStartMB: stemRequiredStartMB,
            stemWindowFloorMB: stemWindowFloorMB,
            physicalMemoryMB: physicalMemoryMB,
            currentHeadroomMB: currentHeadroomMB,
            currentRSSMB: currentRSSMB
        )
    }

    /// Pure projection used by tests — same stage-label rules as the live recorder.
    public static func snapshot(
        from samples: [MemoryBreadcrumbSample],
        peakRSSMB: Int? = nil,
        qualityTier: String,
        avfAudioExceptionCount: Int,
        lastCaughtDescription: String? = nil,
        stemRequiredStartMB: Int,
        stemWindowFloorMB: Int,
        physicalMemoryMB: Int? = nil,
        currentHeadroomMB: Int? = nil,
        currentRSSMB: Int? = nil
    ) -> DiagnosticsBudgetSnapshot {
        let computedPeak = peakRSSMB ?? samples.compactMap(\.rssMB).max()
        return DiagnosticsBudgetSnapshot(
            qualityTier: qualityTier,
            avfAudioExceptionCount: avfAudioExceptionCount,
            lastCaughtDescription: lastCaughtDescription,
            stemRequiredStartMB: stemRequiredStartMB,
            stemWindowFloorMB: stemWindowFloorMB,
            physicalMemoryMB: physicalMemoryMB,
            currentHeadroomMB: currentHeadroomMB,
            currentRSSMB: currentRSSMB,
            peakRSSMB: computedPeak,
            sessionLoadBeginRSSMB: lastRSS(in: samples, label: "ort session load begin"),
            sessionLoadReadyRSSMB: lastRSS(in: samples, label: "ort session ready"),
            windowPeakRSSMB: samples
                .filter { $0.label.hasPrefix("window ") }
                .compactMap(\.rssMB)
                .max(),
            separationDoneRSSMB: lastRSS(in: samples, label: "separation done"),
            sessionDrainRSSMB: lastRSS(in: samples, label: "ort session drain"),
            latestPlaybackHeadroomMB: lastSample(in: samples, label: "playback")?.headroomMB,
            latestPlaybackRSSMB: lastSample(in: samples, label: "playback")?.rssMB,
            recentBreadcrumbs: samples
        )
    }

    private static func lastSample(in samples: [MemoryBreadcrumbSample], label: String) -> MemoryBreadcrumbSample? {
        samples.last { $0.label == label }
    }

    private static func lastRSS(in samples: [MemoryBreadcrumbSample], label: String) -> Int? {
        lastSample(in: samples, label: label)?.rssMB
    }
}

/// Plain-text "stem / playback budget" card for Export Diagnostics Report.
public enum DiagnosticsBudgetCard {
    public static func render(_ snapshot: DiagnosticsBudgetSnapshot) -> String {
        var lines: [String] = []
        lines.append("== Stem / playback budget ==")
        lines.append("adaptive quality tier: \(snapshot.qualityTier)")
        lines.append(
            "stem gate: requiredStart=\(snapshot.stemRequiredStartMB) MB  windowFloor=\(snapshot.stemWindowFloorMB) MB"
        )
        lines.append(mbLine("physical memory", snapshot.physicalMemoryMB))
        lines.append(mbLine("current headroom", snapshot.currentHeadroomMB))
        lines.append(mbLine("current RSS", snapshot.currentRSSMB))
        lines.append(mbLine("peak RSS (this process)", snapshot.peakRSSMB))
        lines.append(mbLine("ORT session load begin RSS", snapshot.sessionLoadBeginRSSMB))
        lines.append(mbLine("ORT session ready RSS", snapshot.sessionLoadReadyRSSMB))
        lines.append(mbLine("window peak RSS", snapshot.windowPeakRSSMB))
        lines.append(mbLine("separation done RSS", snapshot.separationDoneRSSMB))
        lines.append(mbLine("ORT session drain RSS", snapshot.sessionDrainRSSMB))
        lines.append(mbLine("latest playback headroom", snapshot.latestPlaybackHeadroomMB))
        lines.append(mbLine("latest playback RSS", snapshot.latestPlaybackRSSMB))
        lines.append("AVFAudio exceptions caught this session: \(snapshot.avfAudioExceptionCount)")
        lines.append("last caught: \(snapshot.lastCaughtDescription ?? "none")")
        lines.append("")
        lines.append("-- recent mem breadcrumbs (newest last) --")
        if snapshot.recentBreadcrumbs.isEmpty {
            lines.append("(none yet)")
        } else {
            for sample in snapshot.recentBreadcrumbs {
                lines.append(breadcrumbLine(sample))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func mbLine(_ label: String, _ value: Int?) -> String {
        "\(label): \(value.map { "\($0) MB" } ?? "n/a")"
    }

    private static func breadcrumbLine(_ sample: MemoryBreadcrumbSample) -> String {
        var parts = ["mem[\(sample.label)]"]
        if let headroom = sample.headroomMB { parts.append("\(headroom) MB headroom") }
        if let rss = sample.rssMB { parts.append("\(rss) MB rss") }
        return parts.joined(separator: " ")
    }
}
