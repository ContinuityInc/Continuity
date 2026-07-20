import SwiftUI
import Domain
import ContinuityCore

/// A compact, at-a-glance picture of what the DJ transition between two tracks does: the
/// crossfade shape, how the two beat grids line up, and the tempo / key / bass moves being
/// applied. Shown in the Now Playing sheet both while a blend is live (with a moving playhead)
/// and just before a scheduled one begins.
///
/// All the musical facts come from `TransitionPreview.make(...)`, so this view never disagrees
/// with what the audio engine actually does — it only handles presentation.
struct TransitionVisualizationView: View {
    let settings: TransitionSettings
    let outgoing: Track
    let incoming: Track
    let isLive: Bool
    let liveProgress: Double
    let secondsUntil: TimeInterval?

    /// Computed once at construction: `body` reads it in several places (graph + chips), and
    /// as a computed property `TransitionPreview.make` re-ran on every access — 3×+ per frame
    /// during live blends. Pure function of the init inputs, so a stored value is identical.
    private let preview: TransitionPreview

    init(settings: TransitionSettings, outgoing: Track, incoming: Track,
         isLive: Bool, liveProgress: Double, secondsUntil: TimeInterval?) {
        self.settings = settings
        self.outgoing = outgoing
        self.incoming = incoming
        self.isLive = isLive
        self.liveProgress = liveProgress
        self.secondsUntil = secondsUntil
        self.preview = TransitionPreview.make(
            curve: settings.curve,
            duration: settings.durationSeconds,
            outgoingBPM: outgoing.bpm,
            incomingBPM: incoming.bpm,
            outgoingCamelot: outgoing.camelotCode,
            incomingCamelot: incoming.camelotCode,
            beatmatchEnabled: settings.beatmatchEnabled,
            harmonicEnabled: settings.harmonicMixingEnabled,
            bassSwapEnabled: settings.bassSwapEnabled
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            crossfadeGraph
            beatGrid
            chips
        }
        .padding(16)
        .continuityGlass(cornerRadius: 20)
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        if isLive {
            Label("Blending into \(incoming.title)", systemImage: "arrow.triangle.merge")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        } else if let secondsUntil {
            Text("Transition in \(Int(secondsUntil.rounded()))s")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    // MARK: Crossfade graph

    /// Two polylines over the blend window: the outgoing gain falling from full to silent (white)
    /// and the incoming rising from silent to full (accent), traced from the curve's own samples.
    /// While live, a vertical playhead sweeps across at the current transition progress.
    private var crossfadeGraph: some View {
        Canvas { context, size in
            let samples = preview.curve.samples(count: 60)
            guard samples.count > 1 else { return }
            let stepX = size.width / CGFloat(samples.count - 1)

            func point(_ index: Int, _ gain: Double) -> CGPoint {
                CGPoint(x: CGFloat(index) * stepX, y: (1 - CGFloat(gain)) * size.height)
            }

            var outgoingPath = Path()
            var incomingPath = Path()
            for (i, sample) in samples.enumerated() {
                let outPoint = point(i, sample.outgoing)
                let inPoint = point(i, sample.incoming)
                if i == 0 {
                    outgoingPath.move(to: outPoint)
                    incomingPath.move(to: inPoint)
                } else {
                    outgoingPath.addLine(to: outPoint)
                    incomingPath.addLine(to: inPoint)
                }
            }
            context.stroke(outgoingPath, with: .color(.white.opacity(0.85)), lineWidth: 2.5)
            context.stroke(incomingPath, with: .color(Color.accentColor), lineWidth: 2.5)

            if isLive {
                let x = CGFloat(min(max(liveProgress, 0), 1)) * size.width
                var playhead = Path()
                playhead.move(to: CGPoint(x: x, y: 0))
                playhead.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(playhead, with: .color(.white.opacity(0.5)), lineWidth: 1)
            }
        }
        .frame(height: 72)
        .allowsHitTesting(false)
        .animation(.linear(duration: 0.25), value: liveProgress)
    }

    // MARK: Beat grid

    /// A thin two-row tick strip: the outgoing track's tail beats (top, white) against the
    /// incoming track's intro beats (bottom, accent), each mapped into the shared `0...1` blend
    /// axis. A track with no detected beats simply contributes no ticks.
    @ViewBuilder private var beatGrid: some View {
        if !outgoing.beatTimes.isEmpty || !incoming.beatTimes.isEmpty {
            Canvas { context, size in
                let duration = settings.durationSeconds
                let windowEnd = outgoing.audibleEndSeconds ?? outgoing.durationSeconds
                let windowStart = incoming.audibleStartSeconds ?? 0
                let outgoingBeats = BeatWindow.outgoingPositions(
                    beats: outgoing.beatTimes, windowEnd: windowEnd, duration: duration)
                let incomingBeats = BeatWindow.incomingPositions(
                    beats: incoming.beatTimes, windowStart: windowStart, duration: duration)
                let tickHeight = size.height / 2 - 1

                for position in outgoingBeats {
                    let x = CGFloat(position) * size.width
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: 0))
                    tick.addLine(to: CGPoint(x: x, y: tickHeight))
                    context.stroke(tick, with: .color(.white.opacity(0.5)), lineWidth: 1)
                }
                for position in incomingBeats {
                    let x = CGFloat(position) * size.width
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: size.height - tickHeight))
                    tick.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(tick, with: .color(Color.accentColor.opacity(0.6)), lineWidth: 1)
                }
            }
            .frame(height: 14)
            .allowsHitTesting(false)
        }
    }

    // MARK: Chips

    /// The applied transition moves as wrapping capsules — tempo nudge, key match, bass swap,
    /// vocal handling (only meaningful when both tracks have stems), and the curve + duration.
    private var chips: some View {
        ChipFlowLayout(spacing: 8) {
            if let tempo = preview.tempo {
                chip {
                    Text("\(Int(tempo.outgoingBPM))→\(Int(tempo.incomingBPM)) BPM  "
                         + String(format: "%+.1f%%", tempo.percentAdjust))
                }
            }
            if let key = preview.key {
                chip {
                    HStack(spacing: 4) {
                        Text("\(key.outgoingCode)→\(key.incomingCode)")
                        if key.compatible {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                        if key.appliedShiftSemitones != 0 {
                            Text(String(format: "(%+d st)", key.appliedShiftSemitones))
                        }
                    }
                }
            }
            if settings.bassSwapEnabled {
                chip { Label("Bass swap", systemImage: "dial.low.fill") }
            }
            if outgoing.hasStems && incoming.hasStems {
                chip { Text(settings.vocalMode.label) }
            }
            chip { Text("\(curveName(settings.curve)) · \(Int(settings.durationSeconds))s") }
        }
    }

    private func chip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
    }

    /// Local mirror of `TransitionSettingsView`'s private curve-name mapping so the labels match.
    private func curveName(_ curve: CrossfadeCurve) -> String {
        switch curve {
        case .linear: return "Linear"
        case .equalPower: return "Equal Power"
        case .smooth: return "Smooth"
        }
    }
}

/// A minimal wrapping layout so the transition chips flow onto multiple lines within the sheet.
private struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: maxWidth == .infinity ? totalWidth : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
