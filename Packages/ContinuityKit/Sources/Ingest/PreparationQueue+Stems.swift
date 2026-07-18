import AVFoundation
import Domain
import Foundation
import SwiftData
import ContinuityCore
import os

extension PreparationQueue {
    /// Demand-driven stem preparation for the tracks around the play position (called on every
    /// track change). Separation costs CPU-minutes and cache bytes per track, so the library is
    /// **never** separated eagerly — only the neighborhood vocal-aware transitions need next.
    /// Also refreshes the LRU clock and heals links whose files were evicted.
    public func ensureStems(for tracks: [Track], in context: ModelContext) {
        // Diagnostic kill switch: launch argument `-debug.disableStemSeparation YES` rules the
        // whole separation pipeline in/out of a memory repro in one run, no code edits.
        if UserDefaults.standard.bool(forKey: "debug.disableStemSeparation") { return }
        protectedStemKeys = Set(tracks.compactMap(\.youtubeVideoID))
        for track in tracks {
            guard !track.isDemo, track.prepState == .ready,
                  let key = track.youtubeVideoID, track.localRelativePath != nil else { continue }
            reconcileStemLinks(track, in: context)
            if track.hasStems {
                StemCache.markUsed(key: key)   // actively played material stays cache-resident
            } else {
                separateStems(track, in: context)
            }
        }
        // Budget pass on every queue move (not just post-separation): catches overage that
        // accrued outside this code path — e.g. gigabytes of legacy float32 stems.
        let protected = protectedStemKeys
        Task.detached(priority: .utility) {
            StemCache.enforceBudget(protecting: protected)
        }
    }

    /// System memory warning: iOS warns before it jetsams. Abort any in-flight stem separation
    /// (it deletes its partial output; the track plays without stems and retries on a later
    /// `ensureStems` pass) and drop the cached ORT session — staying alive beats finishing stems.
    public func handleMemoryPressure() {
        OnnxStemSeparator.requestAbort()
        OnnxStemSeparator.releaseSession()
    }

    /// Brings a track's stem links in line with the disk: links cached stems that exist unlinked
    /// (e.g. a re-added video), clears links whose files were evicted so `hasStems` tells the
    /// truth and the track becomes eligible for re-separation.
    func reconcileStemLinks(_ track: Track, in context: ModelContext) {
        guard let key = track.youtubeVideoID else { return }
        if let v = track.vocalsRelativePath, let a = track.accompanimentRelativePath,
           FileManager.default.fileExists(atPath: StemCache.url(forRelativePath: v).path),
           FileManager.default.fileExists(atPath: StemCache.url(forRelativePath: a).path) {
            return   // linked and present — nothing to do
        }
        if let v = StemCache.stemFile(key: key, kind: "vocals"),
           let a = StemCache.stemFile(key: key, kind: "accompaniment") {
            track.vocalsRelativePath = StemCache.relativePath(for: v)
            track.accompanimentRelativePath = StemCache.relativePath(for: a)
            try? context.save()
        } else if track.hasStems {
            track.vocalsRelativePath = nil
            track.accompanimentRelativePath = nil
            try? context.save()
        }
    }

    /// Separates the track into vocals + accompaniment stems (very slow, off the main actor),
    /// caching them and pointing the track at them. Best-effort: failure just means no vocal-aware
    /// transition for this track. Serialised via `stemLimiter`; after each separation the cache's
    /// byte budget is enforced (LRU eviction, protecting the play-queue neighborhood).
    private func separateStems(_ track: Track, in context: ModelContext) {
        guard let key = track.youtubeVideoID, let relativePath = track.localRelativePath,
              !stemsInFlight.contains(key) else { return }
        stemsInFlight.insert(key)

        let inputURL = AudioCache.url(forRelativePath: relativePath)
        let vocalsOut = StemCache.vocalsURL(key: key)
        let accompanimentOut = StemCache.accompanimentURL(key: key)
        let limiter = stemLimiter

        Task.detached(priority: .utility) { [weak self] in
            await limiter.acquire()
            // Re-check after the (possibly long) wait for the slot: another queued separation
            // of the same video, or a re-added track, may have written the stems meanwhile —
            // don't spend CPU-minutes redoing them (reconcileStemLinks links them up next pass).
            if StemCache.hasStems(key: key) {
                await limiter.release()
                let queueDrained = await MainActor.run { () -> Bool in
                    guard let self else { return true }
                    self.stemsInFlight.remove(key)
                    return self.stemsInFlight.isEmpty
                }
                if queueDrained { OnnxStemSeparator.releaseSession() }
                return
            }
            do {
                MemoryFootprint.breadcrumb("separation task begin")
                let modelURL = try await StemModelStore.ensureModel()
                MemoryFootprint.breadcrumb("model ensured")
                let separator = OnnxStemSeparator(modelURL: modelURL)
                _ = try separator.separate(inputURL: inputURL, vocalsOut: vocalsOut, accompanimentOut: accompanimentOut)
                await MainActor.run {
                    guard track.modelContext != nil else { return }
                    track.vocalsRelativePath = StemCache.relativePath(for: vocalsOut)
                    track.accompanimentRelativePath = StemCache.relativePath(for: accompanimentOut)
                    try? context.save()
                }
                Logger.stems.info("separated stems for \(key, privacy: .public)")
            } catch {
                // Best-effort — the track still plays without stems — but never silently: a broken
                // separator would otherwise look like "stems just never finish".
                Logger.stems.error("stem separation failed for \(key, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            await limiter.release()

            // Budget pass after every separation. Never evict the active neighborhood or the
            // key we just wrote (it may not be in the protected set if the queue moved on).
            let protected = await MainActor.run { self?.protectedStemKeys ?? [] }
            StemCache.enforceBudget(protecting: protected.union([key]))
            let queueDrained = await MainActor.run { () -> Bool in
                guard let self else { return true }
                self.stemsInFlight.remove(key)
                return self.stemsInFlight.isEmpty
            }
            // Last separation done: free the ORT session's weights instead of holding them
            // under live playback for the rest of the process (jetsam margin on device).
            // The next batch re-pays one model load — an offline job can afford that.
            if queueDrained { OnnxStemSeparator.releaseSession() }
        }
    }
}
