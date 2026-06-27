import Foundation

/// The shape of a crossfade. Each curve maps a normalized progress `t` in `0...1`
/// (0 = transition start, 1 = transition end) to a pair of gains for the outgoing
/// and incoming tracks.
public enum CrossfadeCurve: String, CaseIterable, Sendable, Codable {
    /// Linear gain ramp. Simple, but dips ~6 dB in perceived loudness at the midpoint
    /// because two uncorrelated signals at 0.5 linear gain sum quieter than either alone.
    case linear

    /// Equal-power (constant-power) crossfade using sin/cos. The sum of squared gains
    /// is constant (`out^2 + in^2 == 1`), so perceived loudness stays roughly flat
    /// through the blend. This is the default for music transitions.
    case equalPower

    /// Smoothstep ease-in/ease-out applied to an equal-power base, for a gentler start
    /// and end to the blend (useful for long, barely-noticeable transitions).
    case smooth
}

/// A pair of linear amplitude gains (0...1) for the two decks during a crossfade.
public struct CrossfadeGains: Equatable, Sendable {
    /// Gain applied to the outgoing (currently playing) track.
    public let outgoing: Double
    /// Gain applied to the incoming (next) track.
    public let incoming: Double

    public init(outgoing: Double, incoming: Double) {
        self.outgoing = outgoing
        self.incoming = incoming
    }
}

extension CrossfadeCurve {
    /// Returns the outgoing/incoming gains at normalized progress `t`.
    /// `t` is clamped to `0...1`.
    public func gains(at t: Double) -> CrossfadeGains {
        let x = min(max(t, 0), 1)
        switch self {
        case .linear:
            return CrossfadeGains(outgoing: 1 - x, incoming: x)
        case .equalPower:
            let angle = x * .pi / 2
            return CrossfadeGains(outgoing: cos(angle), incoming: sin(angle))
        case .smooth:
            // Smoothstep reshapes the progress, then feed it through equal-power so the
            // constant-power property is preserved while easing the endpoints.
            let s = x * x * (3 - 2 * x)
            let angle = s * .pi / 2
            return CrossfadeGains(outgoing: cos(angle), incoming: sin(angle))
        }
    }

    /// Whether this curve maintains (approximately) constant power across the blend.
    public var isConstantPower: Bool {
        switch self {
        case .linear: return false
        case .equalPower, .smooth: return true
        }
    }
}
