import Foundation
import MetricKit
import UIKit
import os
import Playback
import ContinuityCore

extension Logger {
    /// Crash forensics: MetricKit payload summaries and unclean-exit detection. Filter on
    /// category `crash` in Console after a "transient" crash to see what actually killed the app.
    static let crash = Logger(subsystem: "com.continuity.app", category: "crash")
}

/// Field crash evidence, so a "transient crash" report can name its cause instead of being
/// reasoned about from symptoms.
///
/// Two independent sources:
/// 1. **MetricKit** (`MXMetricManagerSubscriber`): on the launch after a crash, iOS delivers
///    an `MXCrashDiagnostic` with the signal, exception type/code, termination reason and —
///    for Objective-C exceptions, which is what every AVFAudio assertion is — the exception's
///    name and composed message. Payloads are written to Application Support/Diagnostics as
///    JSON and summarised to the `crash` log category.
/// 2. **A dirty-session marker**: a file written at launch and cleared on a clean exit. If it
///    is still present (and not flagged as backgrounded) at the next launch, the previous
///    session died while in the foreground — counted even when no MetricKit payload arrives
///    (jetsam while foregrounded, watchdog kills, a crash on the first launch of a build).
///
/// `writeReport()` bundles both plus device/tier info and the in-process AVFAudio-exception
/// counter into one text file for sharing from Transition settings → Diagnostics.
@MainActor
final class CrashDiagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashDiagnostics()

    // MetricKit invokes `didReceive` off the main actor, so everything it touches is nonisolated.
    nonisolated static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private nonisolated static let maxStoredPayloads = 20
    private nonisolated static let uncleanExitCountKey = "diagnostics.uncleanExitCount"
    private nonisolated static let lastUncleanExitKey = "diagnostics.lastUncleanExit"
    private nonisolated static var sessionMarker: URL { directory.appendingPathComponent("session.marker") }

    private(set) var uncleanExitCount = UserDefaults.standard.integer(forKey: CrashDiagnostics.uncleanExitCountKey)
    private(set) var lastUncleanExit = UserDefaults.standard.object(forKey: CrashDiagnostics.lastUncleanExitKey) as? Date
    /// Diagnostics payloads received in THIS process (MetricKit delivers the previous session's
    /// at launch), summarised for the report.
    private(set) var receivedSummaries: [String] = []
    private var lifecycleObservers: [NSObjectProtocol] = []

    private override init() { super.init() }

    /// Call once at launch, before anything else can crash.
    func start() {
        detectUncleanPreviousSession()
        writeSessionMarker(state: "foreground")
        MXMetricManager.shared.add(self)

        let center = NotificationCenter.default
        // Background terminations (jetsam/suspension) are normal process lifecycle, not
        // crashes: flag the marker so the next launch doesn't count them.
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.writeSessionMarker(state: "background") } })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.writeSessionMarker(state: "foreground") } })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in try? FileManager.default.removeItem(at: CrashDiagnostics.sessionMarker) })
    }

    // MARK: Dirty-session marker

    private func detectUncleanPreviousSession() {
        guard let data = try? Data(contentsOf: Self.sessionMarker),
              let previous = try? JSONDecoder().decode(SessionMarker.self, from: data) else { return }
        defer { try? FileManager.default.removeItem(at: Self.sessionMarker) }
        guard previous.state == "foreground" else { return }
        uncleanExitCount += 1
        lastUncleanExit = Date()
        UserDefaults.standard.set(uncleanExitCount, forKey: Self.uncleanExitCountKey)
        UserDefaults.standard.set(lastUncleanExit, forKey: Self.lastUncleanExitKey)
        Logger.crash.fault("previous session (build \(previous.build, privacy: .public), started \(previous.startedAt.description, privacy: .public)) did not exit cleanly while foregrounded — unclean exits so far: \(self.uncleanExitCount, privacy: .public)")
    }

    private struct SessionMarker: Codable {
        var build: String
        var startedAt: Date
        var state: String
    }

    private func writeSessionMarker(state: String) {
        let marker = SessionMarker(build: Self.buildDescription, startedAt: Self.processStart, state: state)
        guard let data = try? JSONEncoder().encode(marker) else { return }
        try? data.write(to: Self.sessionMarker, options: .atomic)
    }

    // MARK: MXMetricManagerSubscriber

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var summaries: [String] = []
        for payload in payloads {
            let stamp = ISO8601DateFormatter().string(from: payload.timeStampEnd).replacingOccurrences(of: ":", with: "-")
            let url = CrashDiagnostics.directory.appendingPathComponent("diagnostic-\(stamp).json")
            try? payload.jsonRepresentation().write(to: url, options: .atomic)
            summaries.append(contentsOf: Self.summarize(payload))
        }
        Self.pruneStoredPayloads()
        for line in summaries {
            Logger.crash.fault("\(line, privacy: .public)")
        }
        Task { @MainActor in
            CrashDiagnostics.shared.receivedSummaries.append(contentsOf: summaries)
        }
    }

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        // Daily aggregate metrics are not crash evidence; nothing to store.
    }

    private nonisolated static func summarize(_ payload: MXDiagnosticPayload) -> [String] {
        var lines: [String] = []
        let window = "\(payload.timeStampBegin) → \(payload.timeStampEnd)"
        for crash in payload.crashDiagnostics ?? [] {
            var parts = ["crash[\(window)]"]
            if let signal = crash.signal { parts.append("signal=\(signal)") }
            if let type = crash.exceptionType { parts.append("exceptionType=\(type)") }
            if let code = crash.exceptionCode { parts.append("exceptionCode=\(code)") }
            if let reason = crash.terminationReason { parts.append("termination=\(reason)") }
            if let region = crash.virtualMemoryRegionInfo { parts.append("vm=\(region)") }
            // The decisive field for AVFAudio asserts: "required condition is false: …".
            if let objc = crash.exceptionReason {
                parts.append("objcException=\(objc.exceptionName)")
                parts.append("message=\(objc.composedMessage)")
            }
            parts.append("build=\(crash.applicationVersion)")
            lines.append(parts.joined(separator: " "))
        }
        for hang in payload.hangDiagnostics ?? [] {
            lines.append("hang[\(window)] duration=\(hang.hangDuration) build=\(hang.applicationVersion)")
        }
        for pressure in payload.diskWriteExceptionDiagnostics ?? [] {
            lines.append("diskWrite[\(window)] total=\(pressure.totalWritesCaused)")
        }
        for cpu in payload.cpuExceptionDiagnostics ?? [] {
            lines.append("cpuException[\(window)] cpuTime=\(cpu.totalCPUTime) sampled=\(cpu.totalSampledTime)")
        }
        if lines.isEmpty { lines.append("diagnostic[\(window)] payload with no crash/hang entries") }
        return lines
    }

    private nonisolated static func pruneStoredPayloads() {
        let files = storedPayloadURLs()
        for url in files.dropFirst(maxStoredPayloads) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Newest first.
    private nonisolated static func storedPayloadURLs() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return urls
            .filter { $0.lastPathComponent.hasPrefix("diagnostic-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    // MARK: Report

    /// Writes a shareable plain-text report and returns its URL.
    func writeReport() throws -> URL {
        var text = """
        Continuity diagnostics report
        generated: \(Date())
        build: \(Self.buildDescription)
        device: \(Self.deviceModel) iOS \(UIDevice.current.systemVersion)
        physical memory: \(ProcessInfo.processInfo.physicalMemory / 1_048_576) MB
        adaptive quality tier: \(AdaptiveQuality.current().rawValue)
        thermal state: \(ProcessInfo.processInfo.thermalState.rawValue)  low power: \(ProcessInfo.processInfo.isLowPowerModeEnabled)

        unclean foreground exits (all time): \(uncleanExitCount)
        last unclean exit: \(lastUncleanExit.map { "\($0)" } ?? "none")
        AVFAudio exceptions caught this session: \(AVFAudioGuard.caughtExceptionCount)
        last caught: \(AVFAudioGuard.lastCaughtDescription ?? "none")

        """

        text += "\n== MetricKit summaries received this launch ==\n"
        text += receivedSummaries.isEmpty ? "(none)\n" : receivedSummaries.joined(separator: "\n") + "\n"

        text += "\n== MetricKit past diagnostic payloads (system-retained) ==\n"
        let past = MXMetricManager.shared.pastDiagnosticPayloads
        text += past.isEmpty ? "(none)\n" : past.flatMap(Self.summarize).joined(separator: "\n") + "\n"

        let stored = Self.storedPayloadURLs()
        text += "\n== Stored payload files (\(stored.count)) ==\n"
        text += stored.map(\.lastPathComponent).joined(separator: "\n") + "\n"

        // Full JSON of the newest payload only — enough for a precise read, small enough to share.
        if let newest = stored.first, let data = try? Data(contentsOf: newest) {
            let cap = 200_000
            let json = String(decoding: data.prefix(cap), as: UTF8.self)
            text += "\n== Newest payload JSON (\(newest.lastPathComponent)\(data.count > cap ? ", truncated" : "")) ==\n"
            text += json + "\n"
        }

        let url = Self.directory.appendingPathComponent("continuity-diagnostics.txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Environment

    private static let processStart = Date()

    private static var buildDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
