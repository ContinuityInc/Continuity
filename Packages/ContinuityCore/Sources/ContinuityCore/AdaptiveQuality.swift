import Foundation

/// Performance tier for low-end iOS 26 hardware. Derived from physical RAM, thermal state,
/// and Low Power Mode so the Pro Max can keep full Liquid Glass / 20 Hz UI while an Air-class
/// device sheds compositing and stem pressure before the UI hitchs.
public enum AdaptiveQualityTier: String, Sendable, Equatable, CaseIterable {
    /// High-RAM, cool device — full glass, 20 Hz scrubber, baseline stem budget.
    case full
    /// Mid-RAM or warm — opaque chrome for large surfaces, 10 Hz position publishes, stricter stems.
    case balanced
    /// Low-RAM, serious thermal, or Low Power Mode — most aggressive shedding.
    case constrained
}

/// Pure inputs → tier mapping. Call sites that need live `ProcessInfo` use `current()`.
public enum AdaptiveQuality {
    /// Below this, start at `.balanced` (6 GB).
    public static let balancedMemoryThreshold: UInt64 = 6 * 1024 * 1024 * 1024
    /// Below this, start at `.constrained` (4 GB).
    public static let constrainedMemoryThreshold: UInt64 = 4 * 1024 * 1024 * 1024

    public static func tier(
        physicalMemoryBytes: UInt64,
        thermalSeriousOrWorse: Bool,
        lowPowerMode: Bool
    ) -> AdaptiveQualityTier {
        if thermalSeriousOrWorse || lowPowerMode { return .constrained }
        if physicalMemoryBytes < constrainedMemoryThreshold { return .constrained }
        if physicalMemoryBytes < balancedMemoryThreshold { return .balanced }
        return .full
    }

    /// Live tier from the process environment.
    public static func current() -> AdaptiveQualityTier {
        let info = ProcessInfo.processInfo
        // Thermal state and Low Power Mode are Darwin-only Foundation API; the Linux CI build
        // of this module (core-tests.yml) sees a cool, plugged-in device.
        #if canImport(Darwin)
        let thermalBad = info.thermalState == .serious || info.thermalState == .critical
        let lowPower = info.isLowPowerModeEnabled
        #else
        let thermalBad = false
        let lowPower = false
        #endif
        return tier(
            physicalMemoryBytes: info.physicalMemory,
            thermalSeriousOrWorse: thermalBad,
            lowPowerMode: lowPower
        )
    }

    /// Large non-interactive glass panels (transition card, mini bar) become opaque fills.
    public static func prefersOpaqueChrome(for tier: AdaptiveQualityTier = current()) -> Bool {
        tier != .full
    }

    /// Publish `position` every tick (20 Hz) vs every other tick (10 Hz) when not blending.
    public static func allowsFullTickRate(for tier: AdaptiveQualityTier = current()) -> Bool {
        tier == .full
    }

    /// Pause new stem separations while the device is thermally constrained / LPM.
    public static func shouldDeferStemSeparation(for tier: AdaptiveQualityTier = current()) -> Bool {
        tier == .constrained
    }

    public static func stemRequiredStartMB(for tier: AdaptiveQualityTier = current()) -> Int {
        switch tier {
        case .full: return 1_400
        case .balanced: return 1_600
        case .constrained: return 1_800
        }
    }

    public static func stemHoldSeconds(for tier: AdaptiveQualityTier = current()) -> TimeInterval {
        switch tier {
        case .full: return 60
        case .balanced: return 90
        case .constrained: return 120
        }
    }

    /// List / mini-player artwork decode budget (points × 3× ≈ pixels).
    public static func rowArtworkMaxPixel(for tier: AdaptiveQualityTier = current()) -> Double {
        switch tier {
        case .full: return 150
        case .balanced: return 150
        case .constrained: return 120
        }
    }

    /// Now Playing hero artwork decode budget.
    public static func heroArtworkMaxPixel(for tier: AdaptiveQualityTier = current()) -> Double {
        switch tier {
        case .full: return 900
        case .balanced: return 720
        case .constrained: return 540
        }
    }

    /// Mount only the current pager page + its immediate neighbors when not `.full`.
    public static func mountsAllPagerPages(for tier: AdaptiveQualityTier = current()) -> Bool {
        tier == .full
    }
}
